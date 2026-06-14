// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title VestingVault for Multistage ICO
 * @dev Handles multi-stage vesting with cliff and initial unlock logic.
 */
contract VestingVault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error InvalidToken();
    error UnauthorizedCaller(address caller);
    error VestingAlreadyStarted();
    error StartTimeMustBeFuture(uint256 provided, uint256 current);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidInitialUnlockBps(uint256 bps);
    error CliffExceedsDuration(uint256 cliff, uint256 duration);
    error VaultUnderfunded(uint256 balance, uint256 required);
    error VestingNotStarted();
    error VestingNotStartedYet(uint256 startTime);
    error InvalidRoundIndex(uint256 index);
    error NothingToClaim();
    error NothingToClaimForRound(uint256 round);
    error InvalidRecipient();
    error AmountExceedsUnallocatedBalance(uint256 amount, uint256 excess);
    error CannotRescueIcoToken();
    error EmptyRoundConfig();
    error TooManyRounds(uint256 count, uint256 max);
    error InvalidRoundConfig(uint256 index);

    /**
     * @notice Vesting configuration parameters for a specific round.
     * @dev These parameters are shared by all users who purchase in the same round.
     */
    struct RoundConfig {
        uint32 cliff; // Lock period (seconds) — part of total duration
        uint32 duration; // Total vesting duration in seconds (includes cliff)
        uint16 initialUnlockBps; // Percentage unlocked immediately at TGE (1000 = 10%, max 10000)
    }

    /**
     * @notice User's vesting schedule for a specific round.
     * @dev Only stores user-specific data; vesting parameters are in vestingRounds.
     */
    struct Schedule {
        uint128 totalAmount; // Total tokens purchased in this round
        uint128 claimedAmount; // Amount already withdrawn by user
        uint8 round; // ICO round index
    }

    /// @notice Role allowed to add new vesting schedules (The ICO Contract)
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    /// @notice Upper bound on round count (`uint8` round index in schedules)
    uint256 public constant MAX_ROUNDS = 10;

    /// @notice Number of vesting rounds (matches ICO stage count at deploy time)
    uint256 public immutable roundCount;

    /// @notice Vesting configuration for each round
    RoundConfig[] public vestingRounds;

    /// @notice The ERC20 token being vested
    IERC20 public immutable icoToken;

    /// @notice The unix timestamp when vesting period officially begins
    uint32 public vestingStartTime; // 0 until Admin sets it post-ICO

    /// @notice Cumulative total of all tokens currently committed to vesting schedules
    uint256 public totalAllocated; // Total tokens committed to vesting schedules globally

    /// @notice Maps round index to the total remaining tokens committed globally for that round
    mapping(uint256 => uint256) public totalAllocatedPerRound; // Total tokens committed per round globally

    /// @notice Maps user address and round to their vesting schedule (total purchase amount aggregated per round)
    mapping(address => mapping(uint8 => Schedule)) public userSchedules;

    /**
     * @notice Emitted when the vesting start time is set.
     * @param timestamp The unix timestamp indicating the start of the vesting clocks.
     */
    event VestingStarted(uint256 timestamp);

    /**
     * @notice Emitted when a vesting schedule is created or updated for a user.
     * @param user The address of the investor.
     * @param amount The total amount of tokens in the schedule.
     * @param round The ICO round number.
     */
    event ScheduleAdded(address indexed user, uint256 amount, uint8 round);

    /**
     * @notice Emitted when a user claims total tokens from a specific round.
     * @param user The address of the investor.
     * @param amount The number of tokens successfully claimed.
     * @param round The round num of the tokens were claimed from.
     */
    event TokensClaimedRound(address indexed user, uint256 amount, uint8 round);

    /**
     * @notice Emitted when a user claims all available tokens across all their schedules.
     * @param user The address of the investor.
     * @param amount The total number of tokens successfully claimed.
     */
    event TokensClaimedAll(address indexed user, uint256 amount);

    /**
     * @notice Emitted when the admin deposits tokens into the vault to fund vesting.
     * @param from The address of the admin depositor.
     * @param amount The number of tokens deposited.
     */
    event IcoTokensDeposited(address indexed from, uint256 amount);

    /**
     * @notice Emitted when the admin withdraws unallocated tokens from the vault.
     * @param to The recipient address.
     * @param amount The number of tokens withdrawn.
     */
    event IcoTokensWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Emitted when non-ICO tokens are rescued from the contract.
     * @param token The address of the rescued ERC20 token.
     * @param to The recipient address.
     * @param amount The number of tokens rescued.
     */
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    /**
     * @notice Initializes the contract with the token and per-round vesting rules.
     * @param _icoToken The address of the ERC20 token to be managed by this vault.
     * @param _roundConfigs One entry per ICO stage (same order and length as ICO stages).
     */
    constructor(address _icoToken, RoundConfig[] memory _roundConfigs) {
        if (_icoToken == address(0)) revert InvalidToken();
        if (_roundConfigs.length == 0) revert EmptyRoundConfig();
        if (_roundConfigs.length > MAX_ROUNDS) {
            revert TooManyRounds(_roundConfigs.length, MAX_ROUNDS);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        icoToken = IERC20(_icoToken);
        roundCount = _roundConfigs.length;

        for (uint256 i = 0; i < _roundConfigs.length; i++) {
            RoundConfig memory config = _roundConfigs[i];
            if (config.initialUnlockBps > 10000) {
                revert InvalidRoundConfig(i);
            }
            if (config.cliff > config.duration) {
                revert CliffExceedsDuration(config.cliff, config.duration);
            }
            vestingRounds.push(config);
        }
    }
    // explicit receive function to prevent accidental Native token deposits
    receive() external payable {
        revert("NotSupported()");
    }
    /**
     * @notice Set the vesting start timestamp to begin the vesting clocks.
     * @param _startTime The unix timestamp when vesting period starts.
     * @dev Accessible by the Admin or the ICO contract (via ALLOCATOR_ROLE).
     */
    function startVesting(uint32 _startTime) external {
        if (
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            !hasRole(ALLOCATOR_ROLE, msg.sender)
        ) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (vestingStartTime != 0) revert VestingAlreadyStarted();
        if (_startTime < block.timestamp) {
            revert StartTimeMustBeFuture(_startTime, block.timestamp);
        }

        vestingStartTime = _startTime;
        emit VestingStarted(_startTime);
    }

    /**
     * @notice Adds a new vesting schedule or aggregates to existing schedule for a user.
     * @param _user The address of the investor.
     * @param _round The index of the ICO round.
     * @param _amount The total amount of tokens allocated to this schedule.
     */
    function addSchedule(
        address _user,
        uint8 _round,
        uint128 _amount
    ) external onlyRole(ALLOCATOR_ROLE) {
        if (_user == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        if (_round >= roundCount) revert InvalidRoundIndex(_round);

        uint256 requiredBalance = totalAllocated + _amount;
        uint256 currentBalance = icoToken.balanceOf(address(this));
        if (currentBalance < requiredBalance) {
            revert VaultUnderfunded(currentBalance, requiredBalance);
        }

        // Check if user already has a schedule for this round
        Schedule storage existingSchedule = userSchedules[_user][_round];
        if (existingSchedule.totalAmount == 0) {
            // New schedule for this round
            userSchedules[_user][_round] = Schedule({
                totalAmount: _amount,
                claimedAmount: 0,
                round: _round
            });
        } else {
            // Aggregate to existing schedule (add amounts)
            userSchedules[_user][_round].totalAmount += _amount;
        }

        totalAllocated += _amount;
        totalAllocatedPerRound[_round] += _amount;
        emit ScheduleAdded(
            _user,
            userSchedules[_user][_round].totalAmount,
            _round
        );
    }

    /**
     * @notice Claims all available tokens for a specific ICO round.
     * @param _round The ICO round number to claim tokens from.
     */
    function claimRound(uint8 _round) external nonReentrant whenNotPaused {
        if (vestingStartTime == 0) revert VestingNotStarted();
        if (block.timestamp < vestingStartTime) {
            revert VestingNotStartedYet(vestingStartTime);
        }
        if (_round >= roundCount) revert InvalidRoundIndex(_round);

        Schedule storage s = userSchedules[msg.sender][_round];
        if (s.totalAmount == 0) revert NothingToClaimForRound(_round);

        uint256 vested = _calculateVested(s);
        uint256 claimable = vested - s.claimedAmount;

        if (claimable == 0) revert NothingToClaimForRound(_round);

        s.claimedAmount += uint128(claimable);
        totalAllocated -= claimable;
        totalAllocatedPerRound[s.round] -= claimable;
        icoToken.safeTransfer(msg.sender, claimable);
        emit TokensClaimedRound(msg.sender, claimable, _round);
    }

    /**
     * @notice Claims all available tokens across all rounds for the caller.
     */
    function claimAll() external nonReentrant whenNotPaused {
        if (vestingStartTime == 0) revert VestingNotStarted();
        if (block.timestamp < vestingStartTime) {
            revert VestingNotStartedYet(vestingStartTime);
        }

        uint256 totalClaimable = 0;

        // Loop through all possible rounds
        for (uint256 round = 0; round < roundCount; ++round) {
            Schedule storage s = userSchedules[msg.sender][uint8(round)];
            if (s.totalAmount > 0) {
                uint256 vested = _calculateVested(s);
                uint256 claimable = vested - s.claimedAmount;

                if (claimable > 0) {
                    s.claimedAmount += uint128(claimable);
                    totalAllocated -= claimable;
                    totalClaimable += claimable;
                    totalAllocatedPerRound[s.round] -= claimable;
                }
            }
        }

        if (totalClaimable == 0) revert NothingToClaim();

        icoToken.safeTransfer(msg.sender, totalClaimable);
        emit TokensClaimedAll(msg.sender, totalClaimable);
    }

    // ── Admin Functions ─────────────────────────────────────────────

    /**
     * @notice Pauses token claims in case of emergency.
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token claims.
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Allows admin to deposit ICO tokens into the vault to fund vesting schedules.
     * @param _amount The number of tokens to deposit.
     */
    function depositICOTokens(
        uint256 _amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_amount == 0) revert ZeroAmount();
        icoToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit IcoTokensDeposited(msg.sender, _amount);
    }

    /**
     * @notice Allows admin to withdraw excess (unallocated) ICO tokens from the vault.
     * @param _amount The number of tokens to withdraw.
     * @param _to The recipient address.
     */
    function withdrawIcoTokens(
        uint256 _amount,
        address _to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (_to == address(0)) revert InvalidRecipient();
        uint256 balance = icoToken.balanceOf(address(this));
        uint256 excess = balance - totalAllocated;
        if (_amount > excess) {
            revert AmountExceedsUnallocatedBalance(_amount, excess);
        }
        icoToken.safeTransfer(_to, _amount);
        emit IcoTokensWithdrawn(_to, _amount);
    }

    /**
     * @notice Rescue accidentally sent ERC20 tokens (excluding the ICO token).
     * @param _token The address of the ERC20 token to rescue.
     * @param _amount The number of tokens to rescue.
     * @param _to The recipient address.
     */
    function rescueTokens(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_token == address(icoToken)) revert CannotRescueIcoToken();
        if (_to == address(0)) revert InvalidRecipient();
        IERC20(_token).safeTransfer(_to, _amount);
        emit TokensRescued(_token, _to, _amount);
    }

    // ── View Helpers ────────────────────────────────────────────────

    /**
     * @notice Fetches the vesting schedule for a specific user and round.
     * @param _user The address of the investor.
     * @param _round The ICO round number.
     * @return schedule The Schedule struct containing user-specific data.
     * @return config The RoundConfig struct containing vesting parameters for this round.
     */
    function getSchedule(
        address _user,
        uint8 _round
    )
        external
        view
        returns (Schedule memory schedule, RoundConfig memory config)
    {
        if (_round >= roundCount) revert InvalidRoundIndex(_round);
        schedule = userSchedules[_user][_round];
        config = vestingRounds[_round];
    }

    /**
     * @notice Retrieves a summary of a user's total vesting status across all rounds.
     * @param _user The address of the investor.
     * @return totalAllocatedUser Sum of all tokens allocated to the user.
     * @return totalClaimedUser Sum of all tokens already claimed by the user.
     * @return totalClaimableUser Sum of all tokens currently available to claim.
     */
    function getUserVestingSummary(
        address _user
    )
        external
        view
        returns (
            uint256 totalAllocatedUser,
            uint256 totalClaimedUser,
            uint256 totalClaimableUser
        )
    {
        for (uint256 round = 0; round < roundCount; ++round) {
            Schedule storage s = userSchedules[_user][uint8(round)];
            if (s.totalAmount > 0) {
                uint256 vested = _calculateVested(s);
                totalAllocatedUser += s.totalAmount;
                totalClaimedUser += s.claimedAmount;
                totalClaimableUser += (vested - s.claimedAmount);
            }
        }
        return (totalAllocatedUser, totalClaimedUser, totalClaimableUser);
    }

    /**
     * @notice Retrieves a summary of a user's vesting status for a specific ICO round.
     * @param _user The address of the investor.
     * @param _round The index of the ICO round.
     * @return totalAllocatedRound Tokens allocated to the user in the specified round.
     * @return totalClaimedRound Tokens already claimed by the user from the specified round.
     * @return totalClaimableRound Tokens currently available to claim from the specified round.
     */
    function getUserVestingRoundSummary(
        address _user,
        uint8 _round
    )
        external
        view
        returns (
            uint256 totalAllocatedRound,
            uint256 totalClaimedRound,
            uint256 totalClaimableRound
        )
    {
        if (_round >= roundCount) revert InvalidRoundIndex(_round);
        Schedule storage s = userSchedules[_user][_round];
        if (s.totalAmount > 0) {
            uint256 vested = _calculateVested(s);
            totalAllocatedRound = s.totalAmount;
            totalClaimedRound = s.claimedAmount;
            totalClaimableRound = (vested - s.claimedAmount);
        }
        return (totalAllocatedRound, totalClaimedRound, totalClaimableRound);
    }

    /**
     * @notice Calculates the total vested amount for a given vesting schedule.
     * @param s The vesting schedule (storage reference) for which vested amount is calculated.
     * @dev Intentional design: the cliff is a lock gate within the total duration, NOT a dead zone.
     *      Linear accrual is computed from vestingStartTime (not from cliff end). This means tokens
     *      accrue during the cliff period but remain locked. Once the cliff expires, all accrued
     *      tokens are released as a retroactive lump sum. This is the industry-standard approach
     *      used by OpenZeppelin VestingWalletCliff and Sablier cliff-linear streams.
     *
     *      Timeline visualization (e.g. 10% TGE, 90d cliff, 360d duration, 1000 tokens):
     *        vestingStart ──────── cliff end ──────────────── duration end
     *        |  TGE: 100tk  |  lump sum: 225tk  |  linear continues  |  total: 1000tk
     *        Day 0          Day 90               ...                  Day 360
     *
     * Notes:
     * - This function does not modify state.
     * - Uses storage reference to avoid unnecessary memory copying (gas optimized).
     */
    function _calculateVested(
        Schedule storage s
    ) internal view returns (uint256) {
        if (vestingStartTime == 0 || block.timestamp < vestingStartTime) {
            return 0;
        }

        RoundConfig memory config = vestingRounds[s.round];
        uint256 initialUnlockAmount = (s.totalAmount *
            config.initialUnlockBps) / 10000;

        // If 100% TGE or no duration, return full amount
        if (config.initialUnlockBps == 10000 || config.duration == 0) {
            return s.totalAmount;
        }

        // CLIFF GATE — tokens accrue linearly during cliff but are locked until cliff expires.
        // Only TGE (initialUnlock) is claimable during the cliff period.
        if (block.timestamp < vestingStartTime + config.cliff) {
            return initialUnlockAmount;
        }

        // FULL UNLOCK — cliff is included in duration, so full unlock is at startTime + duration.
        if (block.timestamp >= vestingStartTime + config.duration) {
            return s.totalAmount;
        }

        // LINEAR ACCRUAL — intentionally computed from vestingStartTime (not cliff end).
        // This produces a retroactive lump-sum catch-up at cliff expiry, which is by design.
        uint256 timePassed = block.timestamp - vestingStartTime;
        uint256 remainingTokens = s.totalAmount - initialUnlockAmount;

        uint256 linearVested = (remainingTokens * timePassed) / config.duration;

        return initialUnlockAmount + linearVested;
    }
}
