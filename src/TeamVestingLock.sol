// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TeamVestingLock for ICO Team Tokens
 * @notice Holds the founder's team-token allocation under a 1-year cliff,
 *         3-year linear vesting schedule. Only the single owner (founder)
 *         can fund the vault, start vesting, and claim vested tokens.
 * @dev Uses Ownable2Step so that owner transfer requires explicit acceptance
 *      from the new owner, preventing accidental loss of access.
 */
contract TeamVestingLock is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error InvalidToken();
    error ZeroAddress();
    error ZeroAmount();
    error VestingNotStarted();
    error VestingAlreadyStarted();
    error VestingNotStartedYet(uint256 startTime);
    error FounderAllocationNotFunded();
    error AlreadyFunded();
    error NothingToClaim();
    error TeamTokenRescueExceedsSurplus();
    error NativeTokenNotSupported();
    error InsufficientBalance();
    error NoSurplus();

    /// @notice Cliff period: no tokens are vested before `vestingStartTime + CLIFF`.
    uint256 public constant CLIFF = 365 days;

    /// @notice Total vesting duration including the cliff.
    uint256 public constant DURATION = 3 * 365 days;

    /// @notice The ERC20 token being held.
    IERC20 public immutable teamToken;

    /// @notice Fixed founder allocation used for vesting math.
    uint256 public immutable FOUNDER_ALLOCATION;

    /// @notice Unix timestamp at which vesting starts. Zero before `startVesting` is called.
    uint64 public vestingStartTime;

    /// @notice Total tokens already claimed by the owner.
    uint256 public totalClaimed;

    /// @notice Emitted when vested tokens are claimed.
    event TokensClaimed(address indexed claimer, uint256 amount);

    /// @notice Emitted when non-team tokens are rescued.
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the founder funds the vault.
    event TokensDeposited(address indexed from, uint256 amount);

    /// @notice Emitted when vesting is started.
    event VestingStarted(uint256 startTime, uint256 cliffEnd, uint256 vestingEnd);

    /**
     * @param _teamToken The address of the ERC20 token to be vested.
     * @param _founderAllocation Total tokens that will be locked for the founder.
     */
    constructor(address _teamToken, uint256 _founderAllocation) Ownable(msg.sender) {
        if (_teamToken == address(0)) revert InvalidToken();
        if (_teamToken.code.length == 0) revert InvalidToken();
        if (_founderAllocation == 0) revert ZeroAmount();

        teamToken = IERC20(_teamToken);
        FOUNDER_ALLOCATION = _founderAllocation;
    }

    /// @notice Reject native token transfers. Founder vault accepts ERC20 only.
    receive() external payable {
        revert NativeTokenNotSupported();
    }

    /**
     * @notice Top-up the vault until its balance reaches `FOUNDER_ALLOCATION`.
     *         Idempotent and complements direct ERC20 transfers — either funding
     *         method (or a mix of both) is supported.
     * @dev    Caller must approve at least `(FOUNDER_ALLOCATION - currentBalance)`
     *         tokens to this contract first. Reverts if already fully funded.
     */
    function deposit() external onlyOwner nonReentrant {
        uint256 current = teamToken.balanceOf(address(this));
        if (current >= FOUNDER_ALLOCATION) revert AlreadyFunded();

        uint256 needed;
        unchecked {
            needed = FOUNDER_ALLOCATION - current;
        }
        if (teamToken.balanceOf(msg.sender) < needed) revert InsufficientBalance();

        teamToken.safeTransferFrom(msg.sender, address(this), needed);
        emit TokensDeposited(msg.sender, needed);
    }

    /**
     * @notice Start the vesting clock at the current block timestamp.
     * @dev Callable only once, and only after the contract holds at least
     *      `FOUNDER_ALLOCATION` of the team token. Live balance is the
     *      single source of truth — direct token transfers from the
     *      founder count just like `deposit()` does.
     */
    function startVesting() external onlyOwner {
        if (vestingStartTime != 0) revert VestingAlreadyStarted();
        if (teamToken.balanceOf(address(this)) < FOUNDER_ALLOCATION) {
            revert FounderAllocationNotFunded();
        }
        vestingStartTime = uint64(block.timestamp);
        emit VestingStarted(vestingStartTime, vestingStartTime + CLIFF, vestingStartTime + DURATION);
    }

    /**
     * @notice Claim all currently vested but unclaimed tokens to the owner.
     */
    function claim() external onlyOwner nonReentrant {
        uint256 _start = vestingStartTime;
        if (_start == 0) revert VestingNotStarted();
        if (block.timestamp < _start) revert VestingNotStartedYet(_start);

        uint256 vested = _calculateVested();
        uint256 _claimed = totalClaimed;
        if (vested <= _claimed) revert NothingToClaim();

        uint256 claimable;
        unchecked {
            claimable = vested - _claimed;
        }

        totalClaimed = _claimed + claimable;
        teamToken.safeTransfer(owner(), claimable);

        emit TokensClaimed(owner(), claimable);
    }

    /**
     * @notice Rescue ERC20 tokens accidentally sent to this contract.
     *         For the team token, only the surplus above the unclaimed
     *         vesting obligation (`FOUNDER_ALLOCATION - totalClaimed`) is
     *         rescuable, so the founder can never be shortchanged.
     * @param _token  ERC20 token address (must not be zero).
     * @param _amount Amount to transfer. Must be > 0.
     * @param _to     Recipient address. Must not be zero.
     */
    function rescueTokens(address _token, uint256 _amount, address _to) external onlyOwner {
        if (_token == address(0) || _to == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();

        if (_token == address(teamToken)) {
            uint256 outstanding = FOUNDER_ALLOCATION - totalClaimed;
            uint256 balance = teamToken.balanceOf(address(this));
            if (balance <= outstanding) revert NoSurplus();
            uint256 surplus;
            unchecked {
                surplus = balance - outstanding;
            }
            if (_amount > surplus) revert TeamTokenRescueExceedsSurplus();
        }

        IERC20(_token).safeTransfer(_to, _amount);
        emit TokensRescued(_token, _to, _amount);
    }


    /// @notice Tokens that can be claimed right now.
    function pendingClaim() external view returns (uint256) {
        uint256 vested = _calculateVested();
        uint256 _claimed = totalClaimed;
        return vested > _claimed ? vested - _claimed : 0;
    }

    /**
     * @notice Aggregated view used by dApps.
     * @return allocated Total tokens allocated to the founder.
     * @return claimed   Tokens already claimed by the owner.
     * @return claimable Tokens currently claimable.
     */
    function getVestingInfo()
        external
        view
        returns (uint256 allocated, uint256 claimed, uint256 claimable)
    {
        allocated = FOUNDER_ALLOCATION;
        claimed = totalClaimed;
        uint256 vested = _calculateVested();
        claimable = vested > claimed ? vested - claimed : 0;
    }

    /// @dev Compute total vested amount given current `block.timestamp`.
    function _calculateVested() internal view returns (uint256) {
        uint256 _start = vestingStartTime;
        if (_start == 0 || block.timestamp < _start) return 0;

        uint256 cliffEnd = _start + CLIFF;
        if (block.timestamp < cliffEnd) return 0;

        uint256 vestingEnd = _start + DURATION;
        if (block.timestamp >= vestingEnd) return FOUNDER_ALLOCATION;

        // Linear vesting from cliff end to vestingEnd.
        uint256 timeSinceCliff = block.timestamp - cliffEnd;
        uint256 postCliffPeriod = DURATION - CLIFF;
        return (FOUNDER_ALLOCATION * timeSinceCliff) / postCliffPeriod;
    }

    /**
     * @notice Owner cannot renounce ownership of the lock — would orphan all claims.
     * @dev Disabling renounce is a deliberate safety measure for founder vesting.
     */
    function renounceOwnership() public view override onlyOwner {
        revert("TeamVestingLock: renounce disabled");
    }
}
