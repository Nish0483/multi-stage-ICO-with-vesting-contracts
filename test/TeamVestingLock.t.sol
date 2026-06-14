// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../src/TeamVestingLock.sol";
import "./mocks/MockERC20.sol";

/**
 * @title TeamVestingLock_Test
 * @notice Unit + edge-case tests for the founder vesting lock.
 *
 *  Scenarios covered
 *  ---------------------------------------------------------------
 *   - Constructor validation (zero token, EOA token, zero allocation)
 *   - Native token rejection
 *   - Funding (balance is the single source of truth):
 *        * direct transfer only
 *        * approve + deposit only
 *        * direct transfer THEN deposit() top-up
 *        * deposit() reverts when already funded
 *        * deposit() reverts when caller balance insufficient
 *        * deposit() not callable by stranger
 *        * airdrop dust does not brick funding
 *   - startVesting:
 *        * cannot start without funding
 *        * cannot start twice
 *        * non-owner reverts
 *        * starts at block.timestamp
 *   - Claim:
 *        * before vesting -> NotStarted
 *        * during cliff   -> NothingToClaim
 *        * cliff boundary -> NothingToClaim
 *        * mid-vest math
 *        * full vest
 *        * back-to-back -> NothingToClaim
 *        * non-owner reverts
 *   - Rescue tokens:
 *        * non-team token happy path
 *        * non-team token reverts (zero token / zero to / zero amount / non-owner)
 *        * team token: only surplus above outstanding is rescuable
 *        * team token: no surplus -> NoSurplus
 *        * team token: amount > surplus -> CannotRescueTeamToken
 *   - Ownable2Step transfer:
 *        * pending owner cannot claim until accepted
 *        * after acceptance, tokens flow to new owner
 *   - renounceOwnership disabled
 *   - View helpers: pendingClaim, getVestingInfo
 *   - Fuzz: vesting monotonic, deploy with arbitrary allocations
 */
contract TeamVestingLock_Test is Test {
    TeamVestingLock public lock;
    MockERC20 public token;

    address public founder = address(0xF00D);
    address public stranger = address(0xBEEF);
    address public newOwner = address(0xAB1C);

    uint256 public constant FOUNDER_ALLOCATION = 25_000_000 ether;

    uint256 public constant CLIFF = 365 days;
    uint256 public constant DURATION = 3 * 365 days;

    function setUp() public {
        token = new MockERC20("ICO Token", "ICO", 18);

        vm.prank(founder);
        lock = new TeamVestingLock(address(token), FOUNDER_ALLOCATION);

        token.mint(founder, FOUNDER_ALLOCATION);
    }

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------

    function _approveAndDeposit() internal {
        vm.startPrank(founder);
        token.approve(address(lock), FOUNDER_ALLOCATION);
        lock.deposit();
        vm.stopPrank();
    }

    function _directTransferFund() internal {
        vm.prank(founder);
        token.transfer(address(lock), FOUNDER_ALLOCATION);
    }

    function _bootstrap() internal returns (uint64 startAt) {
        _approveAndDeposit();
        vm.prank(founder);
        lock.startVesting();
        startAt = lock.vestingStartTime();
    }

    // -----------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------

    function test_Constructor_RevertOnZeroToken() public {
        vm.expectRevert(TeamVestingLock.InvalidToken.selector);
        new TeamVestingLock(address(0), FOUNDER_ALLOCATION);
    }

    function test_Constructor_RevertOnEOAToken() public {
        vm.expectRevert(TeamVestingLock.InvalidToken.selector);
        new TeamVestingLock(address(0xDEAD), FOUNDER_ALLOCATION);
    }

    function test_Constructor_RevertOnZeroAllocation() public {
        vm.expectRevert(TeamVestingLock.ZeroAmount.selector);
        new TeamVestingLock(address(token), 0);
    }

    function test_Constructor_StateInitializedCorrectly() public view {
        assertEq(address(lock.teamToken()), address(token));
        assertEq(lock.FOUNDER_ALLOCATION(), FOUNDER_ALLOCATION);
        assertEq(lock.owner(), founder);
        assertEq(lock.vestingStartTime(), 0);
        assertEq(lock.totalClaimed(), 0);
    }

    // -----------------------------------------------------------
    // Native token reject
    // -----------------------------------------------------------

    function test_Receive_RevertsOnNative() public {
        vm.deal(founder, 1 ether);
        vm.prank(founder);
        (bool ok, ) = address(lock).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // -----------------------------------------------------------
    // Funding paths (the new bug fix lives here)
    // -----------------------------------------------------------

    function test_Funding_DirectTransferOnlyEnablesStartVesting() public {
        _directTransferFund();

        assertEq(token.balanceOf(address(lock)), FOUNDER_ALLOCATION);

        vm.prank(founder);
        lock.startVesting();
        assertEq(lock.vestingStartTime(), uint64(block.timestamp));
    }

    function test_Funding_ApproveDepositPath() public {
        _approveAndDeposit();
        assertEq(token.balanceOf(address(lock)), FOUNDER_ALLOCATION);
    }

    function test_Funding_PartialDirectThenDepositTopsUp() public {
        // founder sends half directly
        vm.prank(founder);
        token.transfer(address(lock), FOUNDER_ALLOCATION / 2);

        // mint the remaining half so they can deposit() the rest
        token.mint(founder, FOUNDER_ALLOCATION / 2);

        vm.startPrank(founder);
        token.approve(address(lock), FOUNDER_ALLOCATION / 2);
        lock.deposit();
        vm.stopPrank();

        assertEq(token.balanceOf(address(lock)), FOUNDER_ALLOCATION);
    }

    function test_Deposit_RevertWhenAlreadyFunded() public {
        _directTransferFund();

        // any further deposit() should revert AlreadyFunded
        token.mint(founder, 1);
        vm.startPrank(founder);
        token.approve(address(lock), 1);
        vm.expectRevert(TeamVestingLock.AlreadyFunded.selector);
        lock.deposit();
        vm.stopPrank();
    }

    function test_Deposit_RevertWhenNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        lock.deposit();
    }

    function test_Deposit_RevertWhenInsufficientBalance() public {
        // founder transfers nothing, has full balance, but burns part of it
        vm.prank(founder);
        token.transfer(stranger, 1);

        vm.startPrank(founder);
        token.approve(address(lock), FOUNDER_ALLOCATION);
        vm.expectRevert(TeamVestingLock.InsufficientBalance.selector);
        lock.deposit();
        vm.stopPrank();
    }

    /// @dev Airdrop dust must not brick funding (regression for the original `==` check).
    function test_Funding_AirdropDustDoesNotBrick() public {
        token.mint(stranger, 1);
        vm.prank(stranger);
        token.transfer(address(lock), 1);

        // founder still funds the rest via deposit (top-up handles the missing 1 wei automatically)
        vm.startPrank(founder);
        token.approve(address(lock), FOUNDER_ALLOCATION);
        lock.deposit();
        vm.stopPrank();

        assertGe(token.balanceOf(address(lock)), FOUNDER_ALLOCATION);
    }

    // -----------------------------------------------------------
    // startVesting
    // -----------------------------------------------------------

    function test_StartVesting_RevertWhenNotFunded() public {
        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.FounderAllocationNotFunded.selector);
        lock.startVesting();
    }

    function test_StartVesting_HappyPath() public {
        _approveAndDeposit();
        vm.prank(founder);
        lock.startVesting();
        assertEq(lock.vestingStartTime(), uint64(block.timestamp));
    }

    function test_StartVesting_RevertWhenAlreadyStarted() public {
        _approveAndDeposit();
        vm.prank(founder);
        lock.startVesting();

        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.VestingAlreadyStarted.selector);
        lock.startVesting();
    }

    function test_StartVesting_RevertWhenNotOwner() public {
        _approveAndDeposit();
        vm.prank(stranger);
        vm.expectRevert();
        lock.startVesting();
    }

    // -----------------------------------------------------------
    // claim
    // -----------------------------------------------------------

    function test_Claim_RevertBeforeVestingStarted() public {
        _approveAndDeposit();
        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.VestingNotStarted.selector);
        lock.claim();
    }

    function test_Claim_RevertDuringCliff() public {
        uint64 startAt = _bootstrap();
        vm.warp(startAt + CLIFF - 1);
        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.NothingToClaim.selector);
        lock.claim();
    }

    function test_Claim_AtCliffBoundaryIsZero() public {
        uint64 startAt = _bootstrap();
        vm.warp(startAt + CLIFF);
        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.NothingToClaim.selector);
        lock.claim();
    }

    function test_Claim_LinearMidVest() public {
        uint64 startAt = _bootstrap();
        uint256 halfWay = startAt + CLIFF + (DURATION - CLIFF) / 2;
        vm.warp(halfWay);

        uint256 expected = FOUNDER_ALLOCATION / 2;

        vm.prank(founder);
        lock.claim();

        assertEq(token.balanceOf(founder), expected);
        assertEq(lock.totalClaimed(), expected);
    }

    function test_Claim_FullyVestedAtEnd() public {
        uint64 startAt = _bootstrap();
        vm.warp(startAt + DURATION);

        vm.prank(founder);
        lock.claim();

        assertEq(token.balanceOf(founder), FOUNDER_ALLOCATION);
        assertEq(token.balanceOf(address(lock)), 0);
        assertEq(lock.totalClaimed(), FOUNDER_ALLOCATION);
    }

    function test_Claim_MultipleClaimsSumToAllocation() public {
        uint64 startAt = _bootstrap();

        vm.warp(startAt + CLIFF + (DURATION - CLIFF) / 4);
        vm.prank(founder);
        lock.claim();

        vm.warp(startAt + DURATION);
        vm.prank(founder);
        lock.claim();

        assertEq(token.balanceOf(founder), FOUNDER_ALLOCATION);
        assertEq(token.balanceOf(address(lock)), 0);
    }

    function test_Claim_BackToBackRevertsNothingToClaim() public {
        uint64 startAt = _bootstrap();
        vm.warp(startAt + DURATION);

        vm.prank(founder);
        lock.claim();

        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.NothingToClaim.selector);
        lock.claim();
    }

    function test_Claim_RevertWhenNotOwner() public {
        _bootstrap();
        vm.prank(stranger);
        vm.expectRevert();
        lock.claim();
    }

    // -----------------------------------------------------------
    // rescueTokens — non-team token
    // -----------------------------------------------------------

    function test_Rescue_NonTeamHappyPath() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 18);
        other.mint(address(lock), 100 ether);

        vm.prank(founder);
        lock.rescueTokens(address(other), 100 ether, founder);

        assertEq(other.balanceOf(founder), 100 ether);
    }

    function test_Rescue_RevertOnZeroToken() public {
        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.ZeroAddress.selector);
        lock.rescueTokens(address(0), 1, founder);
    }

    function test_Rescue_RevertOnZeroRecipient() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 18);
        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.ZeroAddress.selector);
        lock.rescueTokens(address(other), 1, address(0));
    }

    function test_Rescue_RevertOnZeroAmount() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 18);
        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.ZeroAmount.selector);
        lock.rescueTokens(address(other), 0, founder);
    }

    function test_Rescue_RevertWhenNotOwner() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 18);
        other.mint(address(lock), 1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        lock.rescueTokens(address(other), 1 ether, stranger);
    }

    // -----------------------------------------------------------
    // rescueTokens — team token surplus rules
    // -----------------------------------------------------------

    function test_Rescue_TeamToken_RevertWhenNoSurplus() public {
        _approveAndDeposit();
        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.NoSurplus.selector);
        lock.rescueTokens(address(token), 1, founder);
    }

    function test_Rescue_TeamToken_RescueOnlySurplusBeforeStart() public {
        // founder over-funds by 2x
        token.mint(founder, FOUNDER_ALLOCATION);
        vm.prank(founder);
        token.transfer(address(lock), 2 * FOUNDER_ALLOCATION);

        // surplus = 2*ALLOC - ALLOC = ALLOC
        vm.prank(founder);
        lock.rescueTokens(address(token), FOUNDER_ALLOCATION, founder);

        assertEq(token.balanceOf(address(lock)), FOUNDER_ALLOCATION);
        assertEq(token.balanceOf(founder), FOUNDER_ALLOCATION);

        // attempting more should revert
        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.NoSurplus.selector);
        lock.rescueTokens(address(token), 1, founder);
    }

    function test_Rescue_TeamToken_RevertWhenAmountExceedsSurplus() public {
        token.mint(founder, 100);
        vm.prank(founder);
        token.transfer(address(lock), FOUNDER_ALLOCATION + 100);

        vm.prank(founder);
        vm.expectRevert(TeamVestingLock.TeamTokenRescueExceedsSurplus.selector);
        lock.rescueTokens(address(token), 101, founder);
    }

    function test_Rescue_TeamToken_AfterFullClaimEverythingIsSurplus() public {
        // direct-transfer over-fund
        token.mint(founder, FOUNDER_ALLOCATION);
        vm.prank(founder);
        token.transfer(address(lock), 2 * FOUNDER_ALLOCATION);

        vm.prank(founder);
        lock.startVesting();
        uint64 startAt = lock.vestingStartTime();

        vm.warp(startAt + DURATION);
        vm.prank(founder);
        lock.claim();

        // all FOUNDER_ALLOCATION claimed; remaining FOUNDER_ALLOCATION is full surplus
        vm.prank(founder);
        lock.rescueTokens(address(token), FOUNDER_ALLOCATION, founder);

        assertEq(token.balanceOf(address(lock)), 0);
    }

    // -----------------------------------------------------------
    // Ownable2Step transfer
    // -----------------------------------------------------------

    function test_OwnerTransfer_PendingOwnerCannotClaimUntilAccept() public {
        uint64 startAt = _bootstrap();

        vm.prank(founder);
        lock.transferOwnership(newOwner);

        assertEq(lock.owner(), founder);
        assertEq(lock.pendingOwner(), newOwner);

        vm.warp(startAt + DURATION);

        vm.prank(newOwner);
        vm.expectRevert();
        lock.claim();

        vm.prank(founder);
        lock.claim();
        assertEq(token.balanceOf(founder), FOUNDER_ALLOCATION);
    }

    function test_OwnerTransfer_AfterAcceptanceTokensFlowToNewOwner() public {
        uint64 startAt = _bootstrap();

        vm.prank(founder);
        lock.transferOwnership(newOwner);

        vm.prank(newOwner);
        lock.acceptOwnership();

        assertEq(lock.owner(), newOwner);

        vm.warp(startAt + DURATION);
        vm.prank(newOwner);
        lock.claim();

        assertEq(token.balanceOf(newOwner), FOUNDER_ALLOCATION);
        assertEq(token.balanceOf(founder), 0);
    }

    function test_RenounceOwnership_Disabled() public {
        vm.prank(founder);
        vm.expectRevert(bytes("TeamVestingLock: renounce disabled"));
        lock.renounceOwnership();
    }

    // -----------------------------------------------------------
    // View helpers
    // -----------------------------------------------------------

    function test_PendingClaim_TracksLinearVesting() public {
        uint64 startAt = _bootstrap();

        assertEq(lock.pendingClaim(), 0);

        vm.warp(startAt + CLIFF + (DURATION - CLIFF) / 2);
        assertEq(lock.pendingClaim(), FOUNDER_ALLOCATION / 2);

        vm.warp(startAt + DURATION + 1);
        assertEq(lock.pendingClaim(), FOUNDER_ALLOCATION);
    }

    function test_GetVestingInfo() public {
        uint64 startAt = _bootstrap();
        vm.warp(startAt + DURATION);

        (uint256 allocated, uint256 claimed, uint256 claimable) = lock.getVestingInfo();
        assertEq(allocated, FOUNDER_ALLOCATION);
        assertEq(claimed, 0);
        assertEq(claimable, FOUNDER_ALLOCATION);

        vm.prank(founder);
        lock.claim();

        (allocated, claimed, claimable) = lock.getVestingInfo();
        assertEq(allocated, FOUNDER_ALLOCATION);
        assertEq(claimed, FOUNDER_ALLOCATION);
        assertEq(claimable, 0);
    }

    // -----------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------

    function testFuzz_VestedAmountMonotonic(uint256 t) public {
        uint64 startAt = _bootstrap();
        t = bound(t, startAt, startAt + DURATION + 365 days);

        vm.warp(t);
        uint256 a = lock.pendingClaim();

        vm.warp(t + 1 days);
        uint256 b = lock.pendingClaim();

        assertGe(b, a);
        assertLe(b, FOUNDER_ALLOCATION);
    }

    function testFuzz_DeployWithVariousAllocations(uint256 alloc) public {
        alloc = bound(alloc, 1, type(uint128).max);
        TeamVestingLock newLock = new TeamVestingLock(address(token), alloc);
        assertEq(newLock.FOUNDER_ALLOCATION(), alloc);
    }
}
