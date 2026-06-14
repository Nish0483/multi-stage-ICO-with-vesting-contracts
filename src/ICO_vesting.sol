// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title IVestingVault
 * @dev Interface of vesting vault to manage token release schedules.
 */
interface IVestingVault {
    /**
     * @notice Adds a new vesting schedule for a user.
     * @param user The address of the investor.
     * @param round The ICO round index.
     * @param amount Total amount of tokens to be vested.
     */
    function addSchedule(address user, uint8 round, uint128 amount) external;

    /**
     * @notice Starts the vesting period for all schedules.
     * @param _startTime The unix timestamp when vesting begins.
     */
    function startVesting(uint32 _startTime) external;

    /// @notice Number of vesting rounds configured at deploy (must match ICO stage count).
    function roundCount() external view returns (uint256);
}

/**
 * @title Multistage_ICO_with_Vesting
 * @notice ICO contract for token sale with multi-stage vesting integration.
 * @dev Manages token sales across different stages with specific pricing, caps, and vesting parameters.
 *      Uses Chainlink oracles for real-time price conversion.
 */
contract ICO is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    //custom errors
    error KYCNotApproved();
    error InvalidStartTime();
    error InvalidTokenAddress();
    error InvalidVaultAddress();
    error InvalidVerifierAddress();
    error ICOInactive();
    error InvalidAmount();
    error TokenNotSupported();
    error InsufficientBalance();
    error StageCapReached();
    error InvalidRecipient();
    error InsufficientETHBalance();
    error ETHTransferFailed();
    error InsufficientTokenBalance();
    error ICOStillActive();
    error InvalidPrice();
    error StalePriceFeed();
    error InvalidPriceFeed();
    error InvalidNumber();
    error BelowMinimumPurchase();
    error InvalidIcoTokenDecimals();
    error EmptyStageConfig();
    error TooManyStages(uint256 count, uint256 max);
    error InvalidStageConfig(uint256 index);
    error StageRoundMismatch(uint256 stages, uint256 rounds);
    error InvalidStageEndTime(uint256 index);

    /**
     * @dev Configuration for supported payment tokens and their respective Chainlink price feeds.
     */
    struct PaymentTokenConfig {
        address token; // address(0) for native token
        address priceFeed; // Chainlink AggregatorV3 address
    }

    /**
     * @dev One ICO stage. At deploy, pass `sold: 0` (constructor resets it anyway).
     */
    struct Stage {
        uint128 cap; // Maximum tokens available in this stage
        uint128 sold; // Tokens sold — only written after deploy
        uint64 price; // Token price in USD (scaled, e.g. 10e12 = $0.000010)
        uint32 endTime; // Timestamp when the stage ends
        uint32 minPurchase; // Minimum purchase in whole USD (e.g. 50 = $50)
    }

    /// @notice Upper bound on stage count (`uint8` stage index in purchase logic)
    uint256 public constant MAX_STAGES = 10;

    /// @notice ICO stages (set in constructor)
    Stage[] public stages;

    /// @notice Number of configured stages
    uint256 public immutable numStages;

    /// @notice Index of the current active stage
    uint8 public currentStage;
    /// @notice Timestamp when the ICO starts
    uint32 public immutable icoStartTime;

    /// @notice Timestamp when the ICO officially ends
    uint32 public immutable icoEndTime;

    /// @notice Threshold for orcale price feed staleness check
    uint32 public stalenessThreshold = 4 hours;

    /// @notice Mapping of payment token address to its Chainlink price feed address
    mapping(address => address) public tokenPriceFeeds;

    /// @notice Mapping to track KYC status of users
    mapping(address => bool) public isKYCApproved;

    /// @notice Total number of unique investors who purchased tokens
    uint32 public numberOfParticipants;

    /// @notice Tracks whether an address has been counted as a participant
    mapping(address => bool) private isParticipant;

    /// @notice Reference to the Vesting Vault contract
    IVestingVault public immutable vestingVault;

    /// @notice Role identifier for accounts allowed to verify KYC
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    /// @notice ERC20 token being sold in the ICO
    IERC20 public immutable icoToken;

    /// @notice Decimals of the ICO token
    uint8 public immutable icoTokenDecimals;

    /**
     * @notice Emitted when tokens are purchased.
     * @param buyer Address of the token purchaser.
     * @param amount Number of ICO tokens purchased.
     * @param price USD price per token at the time of purchase.
     * @param stage The ICO stage index during which the purchase occurred.
     */
    event TokenPurchased(
        address indexed buyer,
        uint256 amount,
        uint256 price,
        uint256 stage
    );

    event RefundedPayment(address indexed buyer, uint256 amount);

    /**
     * @notice Emitted when a payment token's price feed is updated.
     * @param token Address of the payment token.
     * @param priceFeed Address of the Chainlink price feed.
     */
    event PaymentTokenUpdated(address indexed token, address indexed priceFeed);

    /**
     * @notice Emitted when ETH is withdrawn by admin.
     * @param to Recipient address.
     * @param amount Amount of ETH withdrawn.
     */
    event ETHWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Emitted when ERC20 tokens are withdrawn by admin.
     * @param token Address of the ERC20 token.
     * @param to Recipient address.
     * @param amount Amount of tokens withdrawn.
     */
    event ERC20Withdrawn(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    /**
     * @notice Emitted when the ICO advances to the next stage.
     * @param fromStage The index of the previous stage.
     * @param toStage The index of the new active stage.
     */
    event StageAdvanced(uint256 indexed fromStage, uint256 indexed toStage);

    /**
     * @notice Emitted when a user's KYC status is approved.
     * @param user The address of the verified user.
     */
    event KYCApproved(address indexed user);

    /**
     * @notice Emitted when a user's KYC status is revoked.
     * @param user The address of the revoked user.
     */
    event KYCRevoked(address indexed user);

    /**
     * @notice Emitted when a users gets a bonus with respect to volume
     * @param user The address of the revoked user.
     * @param amount The token amount purchased
     * @param bonus received for purchase
     */
    event BonusRewarded(address indexed user, uint256 amount, uint256 bonus);

    /// @dev Modifier to restrict access to KYC-approved users only.
    modifier onlyKYCUser() {
        if (!isKYCApproved[msg.sender]) revert KYCNotApproved();
        _;
    }

    /**
     * @notice Initializes the ICO contract with starting parameters.
     * @param _icoToken Address of the token to be sold.
     * @param _startTime Timestamp when the ICO begins.
     * @param _vestingVault Address of the VestingVault contract
     * @param _verifier Address of the account authorized to verify KYC.(backend wallet)
     * @param _configs Initial list of supported payment tokens and their price feeds.
     * @param _stages Sale stages — array length = number of stages (must match vault round count).
     */
    constructor(
        address _icoToken,
        uint32 _startTime,
        address _vestingVault,
        address _verifier,
        PaymentTokenConfig[] memory _configs,
        Stage[] memory _stages
    ) {
        if (_startTime <= block.timestamp) revert InvalidStartTime();
        if (_icoToken == address(0)) revert InvalidTokenAddress();
        if (_vestingVault == address(0)) revert InvalidVaultAddress();
        if (_verifier == address(0)) revert InvalidVerifierAddress();
        if (_stages.length == 0) revert EmptyStageConfig();
        if (_stages.length > MAX_STAGES) {
            revert TooManyStages(_stages.length, MAX_STAGES);
        }

        IVestingVault vault = IVestingVault(_vestingVault);
        if (_stages.length != vault.roundCount()) {
            revert StageRoundMismatch(_stages.length, vault.roundCount());
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, _verifier);

        icoStartTime = _startTime;
        icoToken = IERC20(_icoToken);
        icoTokenDecimals = IERC20Metadata(_icoToken).decimals();
        if (icoTokenDecimals > 24) revert InvalidIcoTokenDecimals();
        vestingVault = vault;
        numStages = _stages.length;

        for (uint256 i = 0; i < _configs.length; i++) {
            _setPaymentToken(_configs[i].token, _configs[i].priceFeed);
        }

        uint32 lastEndTime;
        for (uint256 i = 0; i < _stages.length; i++) {
            Stage memory cfg = _stages[i];
            if (cfg.cap == 0 || cfg.price == 0 || cfg.minPurchase == 0) {
                revert InvalidStageConfig(i);
            }
            if (cfg.endTime <= _startTime) {
                revert InvalidStageEndTime(i);
            }
            if (i > 0 && cfg.endTime < lastEndTime) {
                revert InvalidStageEndTime(i);
            }

            stages.push(
                Stage({
                    cap: cfg.cap,
                    sold: 0,
                    price: cfg.price,
                    endTime: cfg.endTime,
                    minPurchase: cfg.minPurchase
                })
            );
            lastEndTime = cfg.endTime;
        }

        icoEndTime = lastEndTime;
    }

    // explicit receive function to prevent accidental ETH deposits
    receive() external payable {
        revert("Use buyTokenWithNative()");
    }

    // ── Buy Functions ───────────────────────────────────────────────
    /**
     * @notice Allows users to purchase ICO tokens using supported ERC20 tokens.
     * @dev Calculates the amount of tokens based on real-time USD price from Chainlink.
     *      Adds a vesting schedule for the user in the VestingVault.
     * @param _paymentToken The address of the ERC20 token used for payment.
     * @param _paymentTokenAmount The amount of payment tokens to spend.
     */
    function buyTokenWithERC20(
        address _paymentToken,
        uint256 _paymentTokenAmount
    ) external nonReentrant whenNotPaused onlyKYCUser {
        if (block.timestamp < icoStartTime || block.timestamp > icoEndTime) {
            revert ICOInactive();
        }
        if (_paymentTokenAmount == 0) revert InvalidAmount();

        address feedAddress = tokenPriceFeeds[_paymentToken];
        if (feedAddress == address(0)) revert TokenNotSupported();

        _updateStage();
        uint8 sIdx = currentStage;
        Stage memory stage = stages[sIdx];

        (uint256 tokenToReceive, uint256 usdValue) = _calculateTokenAmount(
            _paymentToken,
            _paymentTokenAmount,
            stage.price
        );

        uint256 remainingCap = stage.cap - stage.sold;
        if (remainingCap == 0) revert StageCapReached();

        // Check minimum purchase
        if (usdValue < uint256(stage.minPurchase) * 1e18)
            revert BelowMinimumPurchase();

        // Normal purchase - no token cap/round exceed
        if (tokenToReceive < remainingCap) {
            if (
                IERC20(_paymentToken).balanceOf(msg.sender) <
                _paymentTokenAmount
            ) {
                revert InsufficientBalance();
            }

            IERC20(_paymentToken).safeTransferFrom(
                msg.sender,
                address(this),
                _paymentTokenAmount
            );

            stages[sIdx].sold += uint128(tokenToReceive);
            uint bonus = checkBonus(tokenToReceive);
            vestingVault.addSchedule(
                msg.sender,
                sIdx,
                uint128(tokenToReceive + bonus)
            );
            emit TokenPurchased(msg.sender, tokenToReceive, stage.price, sIdx);
            if (bonus > 0)
                emit BonusRewarded(msg.sender, tokenToReceive, bonus);

            if (!isParticipant[msg.sender]) {
                isParticipant[msg.sender] = true;
                numberOfParticipants++;
            }
            return;
        }

        // requested amount exceeds a round cap
        _handleCapExceedPurchase(
            msg.sender,
            _paymentTokenAmount,
            _paymentToken,
            sIdx,
            tokenToReceive
        );

        if (!isParticipant[msg.sender]) {
            isParticipant[msg.sender] = true;
            numberOfParticipants++;
        }
    }

    /**
     * @notice Allows users to purchase ICO tokens using the native currency (e.g., ETH).
     * @dev Calculates the amount of tokens based on real-time USD price from Chainlink.
     *      Adds a vesting schedule for the user in the VestingVault.
     */
    function buyTokenWithNative()
        external
        payable
        nonReentrant
        whenNotPaused
        onlyKYCUser
    {
        if (block.timestamp < icoStartTime || block.timestamp > icoEndTime) {
            revert ICOInactive();
        }
        if (msg.value == 0) revert InvalidAmount();

        _updateStage();
        uint8 sIdx = currentStage;
        Stage memory stage = stages[sIdx];

        (uint256 tokenToReceive, uint256 usdValue) = _calculateTokenAmount(
            address(0),
            msg.value,
            stage.price
        );

        uint256 remainingCap = stage.cap - stage.sold;
        if (remainingCap == 0) revert StageCapReached();

        // Check minimum purchase
        if (usdValue < uint256(stage.minPurchase) * 1e18)
            revert BelowMinimumPurchase();

        // Normal purchase - no cap exceed
        if (tokenToReceive < remainingCap) {
            stages[sIdx].sold += uint128(tokenToReceive);
            uint256 bonus = checkBonus(tokenToReceive);

            vestingVault.addSchedule(
                msg.sender,
                sIdx,
                uint128(tokenToReceive + bonus)
            );
            emit TokenPurchased(msg.sender, tokenToReceive, stage.price, sIdx);
            if (bonus > 0)
                emit BonusRewarded(msg.sender, tokenToReceive, bonus);

            if (!isParticipant[msg.sender]) {
                isParticipant[msg.sender] = true;
                numberOfParticipants++;
            }
            return;
        }

        // Cap exceeded
        _handleCapExceedPurchase(
            msg.sender,
            msg.value,
            address(0),
            sIdx,
            tokenToReceive
        );

        if (!isParticipant[msg.sender]) {
            isParticipant[msg.sender] = true;
            numberOfParticipants++;
        }
    }

    // ── Admin functions ────────────────────────────────────────────────

    /**
     * @notice Admin function to add or update a supported payment token.
     */
    function setPaymentToken(
        address _token,
        address _priceFeed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPaymentToken(_token, _priceFeed);
        emit PaymentTokenUpdated(_token, _priceFeed);
    }

    /**
     * @notice Withdraw ETH from the contract.
     */
    function withdrawETH(
        uint256 amount,
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        if (address(this).balance < amount) revert InsufficientETHBalance();
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
        emit ETHWithdrawn(to, amount);
    }

    /**
     * @notice Withdraw ERC20 tokens from the contract.
     */
    function withdrawERC20(
        address tokenAddress,
        uint256 amount,
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        if (to == address(0)) revert InvalidRecipient();
        IERC20 token = IERC20(tokenAddress);
        if (token.balanceOf(address(this)) < amount) {
            revert InsufficientTokenBalance();
        }
        token.safeTransfer(to, amount);
        emit ERC20Withdrawn(tokenAddress, to, amount);
    }

    /**
     * @notice Approves a user's KYC status.
     * @param user The address to verify.
     */
    function verifyUser(address user) external onlyRole(VERIFIER_ROLE) {
        isKYCApproved[user] = true;
        emit KYCApproved(user);
    }

    /**
     * @notice Revokes a user's KYC status.
     * @param user The address to revoke.
     */
    function revokeVerifiedUser(address user) external onlyRole(VERIFIER_ROLE) {
        isKYCApproved[user] = false;
        emit KYCRevoked(user);
    }

    /**
     * @notice Finalizes the ICO and triggers the start of the vesting period.
     * @dev Can only be called after the ICO end time.
     */
    function startVesting(
        uint32 _startTime
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_startTime <= icoEndTime) revert ICOStillActive();
        vestingVault.startVesting(_startTime);
    }

    /**
     * @notice Pauses token purchases and other restricted operations.
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses operations.
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setStalenessThreshold(
        uint32 _newThreshold
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newThreshold < 60 || _newThreshold > 1 days)
            revert InvalidNumber();
        stalenessThreshold = _newThreshold;
    }

    // ──── View functions ────────────────────────────────────────────────

    /**
     * @notice Returns the price of a payment token using Chainlink oracles.
     * @dev Full Chainlink validation: price > 0, round completeness, staleness, and timestamp sanity.
     * @param _paymentToken The address of the token (use address(0) for native token).
     * @return tokenPrice The current price of the token in USD.
     * @return decimals The number of decimals used by the price feed.
     */
    function getTokenPrice(
        address _paymentToken
    ) public view returns (uint256, uint8) {
        address feedAddress = tokenPriceFeeds[_paymentToken];
        if (feedAddress == address(0)) revert TokenNotSupported();

        AggregatorV3Interface feed = AggregatorV3Interface(feedAddress);
        (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feed.latestRoundData();

        // Price must be positive
        if (price <= 0) revert InvalidPrice();
        // Round must be complete (answeredInRound >= roundId)
        if (answeredInRound < roundId) revert StalePriceFeed();
        // Round must have actually started
        if (startedAt == 0) revert InvalidPriceFeed();
        // updatedAt must be non-zero (defensive against zero defaults)
        if (updatedAt == 0) revert StalePriceFeed();
        // Staleness check — price must not be older than 4 hours
        if (block.timestamp - updatedAt >= stalenessThreshold)
            revert StalePriceFeed();

        uint256 tokenPrice = uint256(price);
        uint8 decimals = feed.decimals();
        return (tokenPrice, decimals);
    }

    /**
     * @notice Returns the effective current stage accounting for time and cap,
     *         without modifying state.
     * @return The predicted current stage index.
     */
    function getEffectiveStage() public view returns (uint256) {
        uint256 stage = currentStage;
        uint256 lastStage = numStages - 1;
        while (
            stage < lastStage &&
            (stages[stage].sold >= stages[stage].cap ||
                block.timestamp >= stages[stage].endTime)
        ) {
            stage++;
        }
        return stage;
    }

    /**
     * @notice Retrieves the data for the currently active (or effective) stage.
     * @return price Token price in USD.
     * @return cap Total token cap for the stage.
     * @return sold Tokens sold in this stage.
     * @return endTime Timestamp when the stage ends.
     */
    function getCurrentStageData()
        external
        view
        returns (uint256 price, uint256 cap, uint256 sold, uint256 endTime)
    {
        uint256 effectiveStage = getEffectiveStage();
        Stage memory stage = stages[effectiveStage];
        return (stage.price, stage.cap, stage.sold, stage.endTime);
    }

    /**
     * @notice Provides a global summary of the ICO sales across all stages.
     * @return totalSoldGlobal Cumulative tokens sold.
     * @return totalCapGlobal Cumulative token cap across all stages.
     */
    function getIcoSummary()
        external
        view
        returns (uint256 totalSoldGlobal, uint256 totalCapGlobal)
    {
        for (uint256 i = 0; i < numStages; i++) {
            totalSoldGlobal += stages[i].sold;
            totalCapGlobal += stages[i].cap;
        }
    }

    /**
     * @notice Returns the configuration of all ICO stages.
     * @return An array of Stage structs.
     */
    function getAllStages() external view returns (Stage[] memory) {
        Stage[] memory stagesArray = new Stage[](numStages);
        for (uint256 i = 0; i < numStages; i++) {
            stagesArray[i] = stages[i];
        }
        return stagesArray;
    }

    // ── Internal functions ────────────────────────────────────────────────

    /**
     * @notice Internal function to set a payment token's price feed.
     * @notice address(0) is allowed for _token refering native token like 'ETH'
     * @param _token The address of the payment token.
     * @param _priceFeed The address of the Chainlink AggregatorV3.
     */
    function _setPaymentToken(address _token, address _priceFeed) internal {
        if (_priceFeed == address(0)) revert InvalidPriceFeed();
        tokenPriceFeeds[_token] = _priceFeed;
    }

    function _calculateTokenAmount(
        address _paymentToken,
        uint256 _paymentTokenAmount,
        uint256 _icoTokenPrice
    ) internal view returns (uint256 tokenToReceive, uint256 usdValue) {
        (uint256 price, uint256 oracleDecimals) = getTokenPrice(_paymentToken);
        uint256 tokenDecimals;

        if (_paymentToken == address(0)) {
            tokenDecimals = 18; // only evm chains used here
        } else {
            tokenDecimals = IERC20Metadata(_paymentToken).decimals();
        }

        // Step 1: Calculate USD value of payment amount
        usdValue =
            (_paymentTokenAmount * price * 1e18) /
            (10 ** tokenDecimals * 10 ** oracleDecimals);

        // Step 2: Calculate tokens to receive based on stage price
        tokenToReceive = (usdValue * (10 ** icoTokenDecimals)) / _icoTokenPrice;

        return (tokenToReceive, usdValue);
    }

    function checkBonus(uint256 amount) internal view returns (uint256) {
        if (amount >= 10_000_000 * (10 ** icoTokenDecimals)) {
            return ((amount * 3) / 100);
        } else return 0;
    }

    /**
     * @notice Internal function to update the current stage if the current one has ended.
     * @dev Checks both time and sales cap to advance the stage index.
     */
    function _updateStage() internal {
        uint256 previousStage = currentStage;
        while (
            currentStage < stages.length - 1 &&
            (stages[currentStage].sold >= stages[currentStage].cap ||
                block.timestamp >= stages[currentStage].endTime)
        ) {
            currentStage++;
        }
        if (currentStage != previousStage) {
            emit StageAdvanced(previousStage, currentStage);
        }
    }

    /**
     * @notice Handles multi-stage purchase when current stage cap is exceeded
     * @param buyer Address of purchaser
     * @param totalPayment Total payment amount (msg.value or ERC20 amount)
     * @param paymentToken Payment token address (address(0) for native)
     * @param initialStage Stage where purchase started
     * @param initialTokensRequested Tokens originally requested in initial stage
     */
    function _handleCapExceedPurchase(
        address buyer,
        uint256 totalPayment,
        address paymentToken,
        uint8 initialStage,
        uint256 initialTokensRequested
    ) internal {
        uint256 paymentToSpend = totalPayment;

        // Fill current stage cap first
        {
            Stage memory _currentStage = stages[initialStage];
            uint256 remainingCap = _currentStage.cap - _currentStage.sold;
            uint256 paymentForCurrentStage = (totalPayment * remainingCap +
                initialTokensRequested -
                1) / initialTokensRequested;

            if (paymentToken != address(0)) {
                IERC20(paymentToken).safeTransferFrom(
                    buyer,
                    address(this),
                    paymentForCurrentStage
                );
            }

            stages[initialStage].sold += uint128(remainingCap);
            vestingVault.addSchedule(
                buyer,
                initialStage,
                uint128(remainingCap + checkBonus(remainingCap))
            );
            emit TokenPurchased(
                buyer,
                remainingCap,
                _currentStage.price,
                initialStage
            );
            if (checkBonus(remainingCap) > 0)
                emit BonusRewarded(
                    buyer,
                    remainingCap,
                    checkBonus(remainingCap)
                );

            paymentToSpend -= paymentForCurrentStage;
        }

        //update stage data
        _updateStage();

        while (paymentToSpend > 0 && currentStage < numStages) {
            uint256 tokensToBuy;
            uint256 paymentForStage;
            bool stageFilled;

            {
                Stage memory stage = stages[currentStage];
                uint256 availableCap = stage.cap - stage.sold;
                if (availableCap == 0) break;

                (
                    uint256 tokensCanBuy,
                    uint256 usdValue
                ) = _calculateTokenAmount(
                        paymentToken,
                        paymentToSpend,
                        stage.price
                    );
                if (tokensCanBuy == 0) break;

                uint256 stageMinUSD = uint256(stage.minPurchase) * 1e18;
                if (usdValue < stageMinUSD) break;

                tokensToBuy = tokensCanBuy >= availableCap
                    ? availableCap
                    : tokensCanBuy;
                paymentForStage =
                    (paymentToSpend * tokensToBuy + tokensCanBuy - 1) /
                    tokensCanBuy;

                if (paymentToken != address(0)) {
                    IERC20(paymentToken).safeTransferFrom(
                        buyer,
                        address(this),
                        paymentForStage
                    );
                }

                stages[currentStage].sold += uint128(tokensToBuy);
                vestingVault.addSchedule(
                    buyer,
                    currentStage,
                    uint128(tokensToBuy + checkBonus(tokensToBuy))
                );
                emit TokenPurchased(
                    buyer,
                    tokensToBuy,
                    stage.price,
                    currentStage
                );
                 if (checkBonus(tokensToBuy) > 0)
                emit BonusRewarded(
                    buyer,
                    tokensToBuy,
                    checkBonus(tokensToBuy)
                );

                stageFilled = (tokensToBuy == availableCap);
            }

            paymentToSpend -= paymentForStage;

            if (stageFilled) {
                _updateStage();
            } else {
                break;
            }
        }

        if (paymentToken == address(0) && paymentToSpend > 0) {
            (bool success, ) = buyer.call{value: paymentToSpend}("");
            if (!success) revert ETHTransferFailed();
            emit RefundedPayment(buyer, paymentToSpend);
        }
    }
}
