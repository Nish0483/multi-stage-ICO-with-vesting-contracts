// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../src/ICO_vesting.sol";
import "../src/Vesting.sol";
import "../src/IcoDeploymentConfig.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceFeed.sol";

/**
 * Pure-logic harness for stage-fill detection used inside the
 * cross-buy loop. Returns true when a stage's available cap is
 * fully consumed by tokensToBuy.
 */
contract StageFillConditionHarness {
    function isStageFilled(
        uint256 cap,
        uint256 soldBefore,
        uint256 tokensToBuy
    ) external pure returns (bool) {
        uint256 availableCap = cap - soldBefore;
        return tokensToBuy == availableCap;
    }
}

/**
 * Reentrancy harness used to prove cross-buy refund cannot be
 * exploited to re-enter the ICO.
 */
contract ReentrancyAttacker {
    ICO public targetICO;
    bool public attackInProgress;
    uint256 public attackCount;

    constructor(address _ico) {
        targetICO = ICO(payable(_ico));
    }

    receive() external payable {
        if (!attackInProgress && attackCount < 1) {
            attackInProgress = true;
            attackCount++;
            try targetICO.buyTokenWithNative{value: msg.value}() {
                revert("Reentrancy should fail");
            } catch {}
            attackInProgress = false;
        }
    }

    function attack() external payable {
        attackCount = 0;
        attackInProgress = false;
        targetICO.buyTokenWithNative{value: msg.value}();
    }
}

/**
 * @title ICO_FullSuite_Test
 * @notice End-to-end scenarios for the ICO + Vesting flow.
 *         Single setUp, no duplicated coverage.
 */
contract ICO_FullSuite_Test is Test {
    ICO public ico;
    VestingVault public vestingVault;
    MockERC20 public icoToken;
    MockERC20 public usdt;
    MockPriceFeed public nativePriceFeed;
    MockPriceFeed public usdtPriceFeed;
    StageFillConditionHarness public harness;

    address public admin = address(0xAD);
    address public verifier = address(0x123);
    address public buyer = address(0xBB);
    address public buyer2 = address(0xBC);
    address public buyer3 = address(0xBD);
    address public unverified = address(0x999);
    address public treasury = address(0xCAFE);

    uint32 public startTime;

    function setUp() public {
        vm.startPrank(admin);
        startTime = uint32(block.timestamp + 1 days);

        icoToken = new MockERC20("ICO Token", "ICO", 18);
        usdt = new MockERC20("USDT", "USDT", 18);
        nativePriceFeed = new MockPriceFeed(8, int256(2000 * 1e8));
        usdtPriceFeed = new MockPriceFeed(8, int256(1 * 1e8));

        VestingVault.RoundConfig[] memory rounds =
            IcoDeploymentConfig.buildDefaultRounds();
        vestingVault = new VestingVault(address(icoToken), rounds);

        ICO.Stage[] memory stages =
            IcoDeploymentConfig.buildDefaultStages(startTime, 18);

        ICO.PaymentTokenConfig[]
            memory configs = new ICO.PaymentTokenConfig[](2);
        configs[0] = ICO.PaymentTokenConfig(address(0), address(nativePriceFeed));
        configs[1] = ICO.PaymentTokenConfig(address(usdt), address(usdtPriceFeed));

        ico = new ICO(
            address(icoToken),
            startTime,
            address(vestingVault),
            verifier,
            configs,
            stages
        );

        vestingVault.grantRole(vestingVault.ALLOCATOR_ROLE(), address(ico));
        icoToken.mint(address(vestingVault), 206_000_000_000_000 ether);
        vm.stopPrank();

        vm.startPrank(verifier);
        ico.verifyUser(buyer);
        ico.verifyUser(buyer2);
        ico.verifyUser(buyer3);
        vm.stopPrank();

        vm.deal(buyer, 2_000_000 ether);
        vm.deal(buyer2, 2_000_000 ether);
        vm.deal(buyer3, 2_000_000 ether);
        vm.deal(unverified, 100 ether);
        usdt.mint(buyer, 2_000_000_000 ether);
        usdt.mint(buyer2, 2_000_000_000 ether);
        usdt.mint(buyer3, 2_000_000_000 ether);

        harness = new StageFillConditionHarness();
    }

    /* =========================================================
                   STAGE FILL DETECTION (UNIT)
       ========================================================= */

    function test_StageFill_DetectsExactFill() public view {
        assertTrue(harness.isStageFilled(100, 40, 60), "exact fill must be detected");
    }

    function test_StageFill_RejectsPartialFill() public view {
        assertFalse(harness.isStageFilled(100, 40, 30), "partial fill must not be flagged");
    }

    function test_StageFill_RejectsZeroBuy() public view {
        assertFalse(harness.isStageFilled(100, 40, 0), "zero buy must not be flagged");
    }

    /* =========================================================
                       INITIAL STATE + VIEWS
       ========================================================= */

    function test_Setup_InitialDeploymentState() public view {
        assertEq(address(ico.icoToken()), address(icoToken));
        assertEq(address(ico.vestingVault()), address(vestingVault));
        assertEq(ico.icoStartTime(), startTime);
        assertTrue(ico.hasRole(ico.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(ico.tokenPriceFeeds(address(0)), address(nativePriceFeed));
        assertEq(ico.tokenPriceFeeds(address(usdt)), address(usdtPriceFeed));
        assertEq(ico.currentStage(), 0);

        (uint256 totalSold, uint256 totalCap) = ico.getIcoSummary();
        assertEq(totalSold, 0);
        assertEq(totalCap, 200_000_000_000_000 ether);

        ICO.Stage[] memory all = ico.getAllStages();
        assertEq(all.length, ico.numStages());
    }

    function test_View_GetEffectiveStage_TracksCapAndTime() public {
        vm.warp(startTime + 1);
        assertEq(ico.getEffectiveStage(), 0);

        vm.warp(startTime + 30 days + 1);
        assertEq(ico.getEffectiveStage(), 1);
    }

    /* =========================================================
                      LIFECYCLE GATES + KYC
       ========================================================= */

    function test_Lifecycle_PreStartReverts() public {
        vm.prank(buyer);
        vm.expectRevert(ICO.ICOInactive.selector);
        ico.buyTokenWithNative{value: 1 ether}();
    }

    function test_Lifecycle_PostEndReverts() public {
        vm.warp(ico.icoEndTime() + 1);
        vm.prank(buyer);
        vm.expectRevert(ICO.ICOInactive.selector);
        ico.buyTokenWithNative{value: 1 ether}();
    }

    function test_Lifecycle_DirectETHReverts() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        (bool ok, ) = address(ico).call{value: 1 ether}("");
        assertFalse(ok, "direct ETH should be rejected");
    }

    function test_KYC_UnverifiedReverts() public {
        vm.warp(startTime + 1);
        vm.prank(unverified);
        vm.expectRevert(ICO.KYCNotApproved.selector);
        ico.buyTokenWithNative{value: 1 ether}();
    }

    function test_KYC_RevocationBlocksFurtherBuys() public {
        vm.warp(startTime + 1);

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        vm.prank(verifier);
        ico.revokeVerifiedUser(buyer);

        vm.prank(buyer);
        vm.expectRevert(ICO.KYCNotApproved.selector);
        ico.buyTokenWithNative{value: 1 ether}();
    }

    /* =========================================================
                          BASIC PURCHASES
       ========================================================= */

    function test_BuyNative_BasicAllocation() public {
        vm.warp(startTime + 1);

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        (uint256 stage0, , ) = vestingVault.userSchedules(buyer, 0);
        assertEq(stage0, 206_000_000 ether, "1 ETH @ $2000 / $0.00001 = 200M tokens + 3% bonus");
        assertEq(ico.numberOfParticipants(), 1);
    }

    function test_BuyERC20_BasicAllocation() public {
        vm.warp(startTime + 1);

        vm.startPrank(buyer);
        usdt.approve(address(ico), 100 ether);
        ico.buyTokenWithERC20(address(usdt), 100 ether);
        vm.stopPrank();

        (uint256 stage0, , ) = vestingVault.userSchedules(buyer, 0);
        assertEq(stage0, 10_300_000 ether, "$100 / $0.00001 = 10M tokens + 3% bonus");
        assertEq(ico.numberOfParticipants(), 1);
    }

    function test_BuyAggregation_MultipleBuysSameRound() public {
        vm.warp(startTime + 1);

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        (uint256 stage0, , ) = vestingVault.userSchedules(buyer, 0);
        assertEq(stage0, 412_000_000 ether, "buys should aggregate with 3% bonus");
        assertEq(ico.numberOfParticipants(), 1, "same buyer counted once");
    }

    /* =========================================================
                  VALIDATION: MIN / UNSUPPORTED / ZERO
       ========================================================= */

    function test_Validation_BelowMinimumNativeReverts() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        vm.expectRevert(ICO.BelowMinimumPurchase.selector);
        ico.buyTokenWithNative{value: 1 wei}();
    }

    function test_Validation_BelowMinimumERC20Reverts() public {
        vm.warp(startTime + 1);
        vm.startPrank(buyer);
        usdt.approve(address(ico), 99 ether);
        vm.expectRevert(ICO.BelowMinimumPurchase.selector);
        ico.buyTokenWithERC20(address(usdt), 99 ether);
        vm.stopPrank();
    }

    function test_Validation_UnsupportedTokenReverts() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        vm.expectRevert(ICO.TokenNotSupported.selector);
        ico.buyTokenWithERC20(address(0xDEAD), 100 ether);
    }

    function test_Validation_ZeroAmountReverts() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        vm.expectRevert(ICO.InvalidAmount.selector);
        ico.buyTokenWithNative{value: 0}();

        vm.prank(buyer);
        vm.expectRevert(ICO.InvalidAmount.selector);
        ico.buyTokenWithERC20(address(usdt), 0);
    }

    /* =========================================================
                            CROSS-BUY
       ========================================================= */

    function test_CrossBuy_NativeRollover() public {
        vm.warp(startTime + 1);

        (, uint256 cap0, uint256 sold0, ) = ico.getCurrentStageData();
        uint256 stage0Remaining = cap0 - sold0;

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 250_001 ether}();

        (uint256 round0, , ) = vestingVault.userSchedules(buyer, 0);
        (uint256 round1, , ) = vestingVault.userSchedules(buyer, 1);
        assertEq(round0, stage0Remaining + (stage0Remaining * 3) / 100, "stage 0 must fully fill with 3% bonus");
        assertTrue(round1 > 0, "rollover must allocate stage 1");
        assertEq(ico.currentStage(), 1);
    }

    function test_CrossBuy_ERC20Rollover() public {
        vm.warp(startTime + 1);

        vm.startPrank(buyer);
        uint256 totalUsdt = 500_000_100 ether;
        usdt.approve(address(ico), totalUsdt);
        ico.buyTokenWithERC20(address(usdt), totalUsdt);
        vm.stopPrank();

        (uint256 round0, , ) = vestingVault.userSchedules(buyer, 0);
        (uint256 round1, , ) = vestingVault.userSchedules(buyer, 1);
        assertTrue(round0 > 0);
        assertTrue(round1 > 0);
        assertEq(ico.currentStage(), 1);
    }

    function test_CrossBuy_PartialNextStageStops() public {
        vm.warp(startTime + 1);

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 250_001 ether}();

        assertEq(ico.currentStage(), 1, "should stay in stage 1 after partial fill");
    }

    function test_CrossBuy_ExactMinimumTriggersAdvance() public {
        vm.warp(startTime + 1);
        vm.startPrank(buyer);

        (uint256 price, uint256 cap, uint256 sold, ) = ico.getCurrentStageData();
        uint256 remainingTokensUSD = (100 * 1e18) / price;
        uint256 tokensToBuy = cap - sold - remainingTokensUSD;
        uint256 ethAmount = (tokensToBuy * price) / (2000 * 1e18);
        ico.buyTokenWithNative{value: ethAmount}();

        // Buy exactly $100 -> finishes stage 0 and rolls over
        uint256 exactMinEth = (100 * 1e18 * 1e18) / (2000 * 1e18);
        ico.buyTokenWithNative{value: exactMinEth}();

        (uint256 stage0Amount, , ) = vestingVault.userSchedules(buyer, 0);
        (uint256 stage1Amount, , ) = vestingVault.userSchedules(buyer, 1);
        assertTrue(stage0Amount > 0);
        assertTrue(stage1Amount > 0);
        vm.stopPrank();
    }

    function test_CrossBuy_AllStagesSoldRefundsETH() public {
        vm.warp(startTime + 1);

        uint256 buyerEthBefore = buyer.balance;

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1_500_000 ether}();

        (uint256 totalSold, uint256 totalCap) = ico.getIcoSummary();
        assertEq(totalSold, totalCap, "all caps must be sold out");
        assertEq(ico.currentStage(), ico.numStages() - 1, "must be in last stage");

        uint256 buyerEthAfter = buyer.balance;
        assertTrue(buyerEthAfter > 0, "buyer should keep some ETH (refund)");
        assertTrue(buyerEthAfter < buyerEthBefore, "buyer should still spend some ETH");
    }

    function test_CrossBuy_StageCapReachedAfterFullSellout() public {
        // Sequentially fill every stage, then assert the next purchase reverts.
        vm.warp(startTime + 1);
        vm.startPrank(buyer);

        for (uint256 i = 0; i < ico.numStages(); i++) {
            vm.warp(startTime + (i * 30 days) + 1);
            (uint256 price, uint256 cap, uint256 sold, ) = ico.getCurrentStageData();
            uint256 tokensToBuy = cap - sold;
            uint256 ethNeeded = (tokensToBuy * price) / (2000 * 1e18);
            ico.buyTokenWithNative{value: ethNeeded}();
        }

        uint256 balanceBefore = buyer.balance;
        vm.expectRevert(ICO.StageCapReached.selector);
        ico.buyTokenWithNative{value: 10 ether}();
        assertEq(buyer.balance, balanceBefore, "no ETH spent on revert");
        vm.stopPrank();
    }

    /* =========================================================
                     STAGE TRANSITIONS (TIME)
       ========================================================= */

    function test_StageAdvance_TimeAfterStage0End() public {
        vm.warp(startTime + 30 days + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();
        assertEq(ico.currentStage(), 1);
    }

    function test_StageAdvance_PurchaseAtExactStageEnd() public {
        vm.warp(startTime + 30 days);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();
        assertEq(ico.currentStage(), 1);

        // Stage 1 vesting params should match (1) — verifies round routing
        (uint256 cliff, uint256 duration, uint256 tgeBps) = vestingVault
            .vestingRounds(1);
        assertEq(cliff, 30 days);
        assertEq(duration, 180 days);
        assertEq(tgeBps, 2000);
    }

    function test_StageAdvance_ChainsThroughAllStagesByTime() public {
        for (uint256 i = 1; i < ico.numStages(); i++) {
            vm.warp(startTime + (i * 30 days) + 1);
            vm.prank(buyer);
            ico.buyTokenWithNative{value: 0.1 ether}();
            assertEq(ico.currentStage(), i);
        }
    }

    /* =========================================================
                STAGE AUTO-UPDATE (CAP-BASED PATHS)
       ========================================================= */

    function test_StageAutoUpdate_CapBasedNative() public {
        vm.warp(startTime + 1);
        vm.startPrank(buyer);

        (uint256 price, uint256 cap, uint256 sold, ) = ico.getCurrentStageData();
        uint256 ethAmount = ((cap - sold) * price) / (2000 * 1e18);
        ico.buyTokenWithNative{value: ethAmount}();

        assertEq(ico.currentStage(), 1);
        assertEq(ico.getEffectiveStage(), 1);
        vm.stopPrank();
    }

    function test_StageAutoUpdate_CapBasedERC20() public {
        vm.warp(startTime + 1);
        vm.startPrank(buyer);

        (uint256 price, uint256 cap, uint256 sold, ) = ico.getCurrentStageData();
        uint256 usdtAmount = ((cap - sold) * price) / 1e18;
        usdt.approve(address(ico), usdtAmount);
        ico.buyTokenWithERC20(address(usdt), usdtAmount);

        assertEq(ico.currentStage(), 1);
        ICO.Stage[] memory allStages = ico.getAllStages();
        assertEq(allStages[0].sold, cap);
        vm.stopPrank();
    }

    /* =========================================================
                          EDGE CASES
       ========================================================= */

    function test_Edge_MultipleSmallPurchases() public {
        vm.warp(startTime + 1);
        vm.startPrank(buyer);
        for (uint256 i = 0; i < 50; i++) {
            ico.buyTokenWithNative{value: 0.1 ether}();
        }
        (uint256 totalAmount, , ) = vestingVault.userSchedules(buyer, 0);
        assertTrue(totalAmount > 0);
        vm.stopPrank();
    }

    function test_Edge_VeryLargeNativePurchase() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1_000_000 ether}();
        (uint256 totalAmount, , ) = vestingVault.userSchedules(buyer, 0);
        assertTrue(totalAmount > 0);
    }

    function test_Edge_LastFewTokensFromCap_ERC20() public {
        vm.warp(startTime + 1);
        vm.startPrank(buyer);

        (uint256 price, uint256 cap, uint256 sold, ) = ico.getCurrentStageData();
        uint256 tokensToBuy = cap - sold - ((200 * 1e18) / price);
        uint256 usdtAmount = (tokensToBuy * price) / 1e18;
        usdt.approve(address(ico), usdtAmount);
        ico.buyTokenWithERC20(address(usdt), usdtAmount);

        usdt.approve(address(ico), 200 ether);
        ico.buyTokenWithERC20(address(usdt), 200 ether);

        assertEq(ico.currentStage(), 1);
        ICO.Stage[] memory allStages = ico.getAllStages();
        assertEq(allStages[0].sold, cap);
        vm.stopPrank();
    }

    function test_Edge_MaximumUsersInSingleStage() public {
        vm.warp(startTime + 1);
        uint256 numUsers = 100;
        uint256 buyAmount = 0.1 ether;

        for (uint256 i = 0; i < numUsers; i++) {
            address u = address(uint160(0x1000 + i));
            vm.deal(u, buyAmount);
            vm.prank(verifier);
            ico.verifyUser(u);
            vm.prank(u);
            ico.buyTokenWithNative{value: buyAmount}();
        }

        assertEq(ico.numberOfParticipants(), numUsers);
    }

    /* =========================================================
                     ADMIN: PAUSE / WITHDRAW / CONFIG
       ========================================================= */

    function test_Admin_PauseUnpause() public {
        vm.warp(startTime + 1);

        vm.prank(admin);
        ico.pause();

        vm.prank(buyer);
        vm.expectRevert();
        ico.buyTokenWithNative{value: 1 ether}();

        vm.prank(admin);
        ico.unpause();

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();
    }

    function test_Admin_WithdrawETHandERC20() public {
        vm.warp(startTime + 1);

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 2 ether}();

        vm.startPrank(buyer2);
        usdt.approve(address(ico), 500 ether);
        ico.buyTokenWithERC20(address(usdt), 500 ether);
        vm.stopPrank();

        uint256 ethBefore = treasury.balance;
        vm.prank(admin);
        ico.withdrawETH(1 ether, treasury);
        assertEq(treasury.balance, ethBefore + 1 ether);

        uint256 usdtBefore = usdt.balanceOf(treasury);
        vm.prank(admin);
        ico.withdrawERC20(address(usdt), 100 ether, treasury);
        assertEq(usdt.balanceOf(treasury), usdtBefore + 100 ether);
    }

    function test_Admin_WithdrawNonAdminReverts() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        vm.prank(buyer);
        vm.expectRevert();
        ico.withdrawETH(1 ether, buyer);
    }

    function test_Admin_SetStalenessThreshold() public {
        vm.prank(admin);
        ico.setStalenessThreshold(1 hours);
        assertEq(ico.stalenessThreshold(), 1 hours);

        vm.prank(admin);
        vm.expectRevert(ICO.InvalidNumber.selector);
        ico.setStalenessThreshold(30); // < 60s

        vm.prank(admin);
        vm.expectRevert(ICO.InvalidNumber.selector);
        ico.setStalenessThreshold(2 days);
    }

    /* =========================================================
                          ORACLE EDGE CASES
       ========================================================= */

    function test_Oracle_StalePriceFeedReverts() public {
        vm.warp(startTime + 1);
        nativePriceFeed.updateRoundData(
            2,
            block.timestamp - 10 hours,
            block.timestamp - 10 hours,
            2
        );

        vm.prank(buyer);
        vm.expectRevert(ICO.StalePriceFeed.selector);
        ico.buyTokenWithNative{value: 1 ether}();
    }

    function test_Oracle_FutureTimestampPanics() public {
        vm.warp(startTime + 1);
        nativePriceFeed.updateRoundData(
            2,
            block.timestamp + 1 hours,
            block.timestamp + 1 hours,
            2
        );

        vm.prank(buyer);
        vm.expectRevert(); // arithmetic underflow panic — documents R-03 risk
        ico.buyTokenWithNative{value: 1 ether}();
    }

    function test_Oracle_IncompleteRoundReverts() public {
        vm.warp(startTime + 1);
        nativePriceFeed.updateRoundData(5, block.timestamp, block.timestamp, 4);

        vm.prank(buyer);
        vm.expectRevert(ICO.StalePriceFeed.selector);
        ico.buyTokenWithNative{value: 1 ether}();
    }

    /* =========================================================
                            REENTRANCY
       ========================================================= */

    function test_Reentrancy_CrossBuyRefundProtected() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(ico));
        vm.prank(verifier);
        ico.verifyUser(address(attacker));

        vm.warp(startTime + 1);

        // Send enough ETH to fill all stage caps, forcing the refund path.
        vm.deal(address(attacker), 2_000_000 ether);
        attacker.attack{value: 1_500_000 ether}();

        // attackCount==1 proves receive() was invoked during refund.
        // If the reentrancy guard had failed, the receive() would have
        // bubbled the explicit "Reentrancy should fail" revert and the
        // outer attack call would not have completed.
        assertEq(attacker.attackCount(), 1, "refund callback must have been hit once");
        (uint256 totalSold, uint256 totalCap) = ico.getIcoSummary();
        assertEq(totalSold, totalCap, "all caps sold by outer purchase");
    }

    /* =========================================================
                        VESTING START + CLAIMS
       ========================================================= */

    function test_Vesting_StartBeforeICOEndReverts() public {
        uint32 t = uint32(ico.icoEndTime() - 1);
        vm.prank(admin);
        vm.expectRevert(ICO.ICOStillActive.selector);
        ico.startVesting(t);
    }

    function test_Vesting_DoubleStartReverts() public {
        uint32 vStart = ico.icoEndTime() + 1 days;
        vm.prank(admin);
        ico.startVesting(vStart);

        vm.prank(admin);
        vm.expectRevert(VestingVault.VestingAlreadyStarted.selector);
        ico.startVesting(vStart + 1 days);
    }

    function test_Vesting_RoundConfigsMatchAllStages() public view {
        VestingVault.RoundConfig[] memory expected =
            IcoDeploymentConfig.buildDefaultRounds();

        assertEq(vestingVault.roundCount(), expected.length);

        for (uint256 i = 0; i < expected.length; i++) {
            (uint256 cliff, uint256 duration, uint256 tgeBps) = vestingVault
                .vestingRounds(i);
            assertEq(cliff, expected[i].cliff);
            assertEq(duration, expected[i].duration);
            assertEq(tgeBps, expected[i].initialUnlockBps);
        }
    }

    function test_Vesting_TGEClaim() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        uint32 tge = uint32(ico.icoEndTime() + 1 days);
        vm.prank(admin);
        ico.startVesting(tge);
        vm.warp(tge + 1);

        uint256 before = icoToken.balanceOf(buyer);
        vm.prank(buyer);
        vestingVault.claimRound(0);
        uint256 afterBal = icoToken.balanceOf(buyer);

        (uint256 total, , ) = vestingVault.userSchedules(buyer, 0);
        assertEq(afterBal - before, (total * 1000) / 10000, "10% TGE for round 0");
    }

    function test_Vesting_CliffPeriodLocked() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        uint32 tge = uint32(ico.icoEndTime() + 1 days);
        vm.prank(admin);
        ico.startVesting(tge);
        vm.warp(tge + 1);

        vm.prank(buyer);
        vestingVault.claimRound(0); // claim TGE only

        // 45 days into cliff — should not release more
        vm.warp(tge + 45 days);
        vm.prank(buyer);
        vm.expectRevert();
        vestingVault.claimRound(0);
    }

    function test_Vesting_LinearVestingMidway() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();
        uint256 totalTokens = 206_000_000 ether;

        uint32 tge = uint32(ico.icoEndTime() + 1 days);
        vm.prank(admin);
        ico.startVesting(tge);
        vm.warp(tge);

        vm.prank(buyer);
        vestingVault.claimRound(0); // 10% TGE

        // 90d cliff + half of remaining 270d duration => after 90+135 days from tge
        uint256 halfDur = 135 days;
        vm.warp(tge + 90 days + halfDur);
        vm.prank(buyer);
        vestingVault.claimRound(0);

        uint256 expectedLinearPart = (((totalTokens * 9000) / 10000) *
            (90 days + halfDur)) / 360 days;
        uint256 expected = ((totalTokens * 1000) / 10000) + expectedLinearPart;
        assertApproxEqAbs(icoToken.balanceOf(buyer), expected, 1e18);
    }

    function test_Vesting_FullCompletion() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        uint32 tge = uint32(ico.icoEndTime() + 1 days);
        vm.prank(admin);
        ico.startVesting(tge);

        vm.warp(tge + 360 days + 1);
        vm.prank(buyer);
        vestingVault.claimRound(0);

        (uint256 total, uint256 claimed, ) = vestingVault.userSchedules(buyer, 0);
        assertEq(total, claimed, "all tokens released after full duration");
    }

    function test_Vesting_ClaimAllAcrossRounds() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        vm.warp(startTime + 30 days + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        uint32 tge = uint32(ico.icoEndTime() + 1 days);
        vm.prank(admin);
        ico.startVesting(tge);
        vm.warp(tge + 1);

        uint256 before = icoToken.balanceOf(buyer);
        vm.prank(buyer);
        vestingVault.claimAll();
        uint256 afterBal = icoToken.balanceOf(buyer);

        (uint256 total0, , ) = vestingVault.userSchedules(buyer, 0);
        (uint256 total1, , ) = vestingVault.userSchedules(buyer, 1);
        uint256 expected = ((total0 * 1000) / 10000) + ((total1 * 2000) / 10000);
        assertApproxEqAbs(afterBal - before, expected, 2);
    }

    function test_Vesting_ClaimRoundIdempotent() public {
        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        uint32 tge = uint32(ico.icoEndTime() + 1 days);
        vm.prank(admin);
        ico.startVesting(tge);
        vm.warp(tge + 1);

        vm.prank(buyer);
        vestingVault.claimRound(0);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                VestingVault.NothingToClaimForRound.selector,
                0
            )
        );
        vestingVault.claimRound(0);
    }

    /* =========================================================
                          INTEGRATION
       ========================================================= */

    function test_Integration_EndToEndMultiBuyer() public {
        vm.warp(startTime + 1);

        vm.prank(buyer);
        ico.buyTokenWithNative{value: 2 ether}();

        vm.warp(startTime + 31 days);
        vm.startPrank(buyer2);
        usdt.approve(address(ico), 1000 ether);
        ico.buyTokenWithERC20(address(usdt), 1000 ether);
        vm.stopPrank();

        vm.warp(startTime + 61 days);
        vm.prank(buyer3);
        ico.buyTokenWithNative{value: 3 ether}();

        uint32 tge = uint32(ico.icoEndTime() + 1 days);
        vm.prank(admin);
        ico.startVesting(tge);
        vm.warp(tge + 1);

        address[3] memory allBuyers = [buyer, buyer2, buyer3];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(allBuyers[i]);
            vestingVault.claimAll();
            assertTrue(icoToken.balanceOf(allBuyers[i]) > 0);
        }

        vm.warp(tge + 400 days);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(allBuyers[i]);
            try vestingVault.claimAll() {} catch {}
            assertTrue(icoToken.balanceOf(allBuyers[i]) > 0);
        }
    }

    function test_Integration_MaximumCapacity() public {
        address[10] memory users;
        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(uint160(0x2000 + i));
            vm.deal(users[i], 1000 ether);
            vm.prank(verifier);
            ico.verifyUser(users[i]);
        }

        for (uint256 stage = 0; stage < ico.numStages(); stage++) {
            vm.warp(startTime + (stage * 30 days) + 1);
            for (uint256 u = 0; u < 10; u++) {
                vm.prank(users[u]);
                ico.buyTokenWithNative{value: 100 ether}();
            }
        }

        assertTrue(ico.currentStage() >= ico.numStages() - 1);

        uint32 tge = uint32(ico.icoEndTime() + 1 days);
        vm.prank(admin);
        ico.startVesting(tge);
        vm.warp(tge + 1);

        for (uint256 i = 0; i < 10; i++) {
            uint256 b = icoToken.balanceOf(users[i]);
            vm.prank(users[i]);
            vestingVault.claimAll();
            assertTrue(icoToken.balanceOf(users[i]) > b);
        }
    }

    /* =========================================================
                            FUZZ
       ========================================================= */

    function testFuzz_BuyNative(uint256 amount) public {
        amount = bound(amount, 0.05 ether, 1000 ether);
        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: amount}();
    }

    function testFuzz_BuyERC20(uint256 amount) public {
        amount = bound(amount, 100 * 1e18, 1_000_000 * 1e18);
        vm.warp(startTime + 1);
        vm.startPrank(buyer);
        usdt.approve(address(ico), amount);
        ico.buyTokenWithERC20(address(usdt), amount);
        vm.stopPrank();
    }

    function testFuzz_PriceFeedValues(uint256 ethPrice) public {
        ethPrice = bound(ethPrice, 100, 100_000);
        nativePriceFeed.updatePrice(int256(ethPrice * 1e8));

        vm.warp(startTime + 1);
        vm.prank(buyer);
        ico.buyTokenWithNative{value: 1 ether}();

        (uint256 totalAmount, , ) = vestingVault.userSchedules(buyer, 0);
        assertTrue(totalAmount > 0);
    }

    function testFuzz_CrossBuyScenarios(uint256 stageToReach, uint256 amount)
        public
    {
        stageToReach = bound(stageToReach, 0, ico.numStages() - 1);
        amount = bound(amount, 0.5 ether, 1000 ether);

        vm.warp(startTime + 1);
        if (stageToReach > 0) {
            vm.warp(startTime + (30 days * stageToReach) + 1);
        }

        vm.prank(buyer);
        ico.buyTokenWithNative{value: amount}();
    }

    function testFuzz_MultiplePurchasesSameUser(uint256[] memory amounts)
        public
    {
        vm.assume(amounts.length > 0 && amounts.length < 10);
        vm.warp(startTime + 1);
        vm.startPrank(buyer);
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 0.05 ether, 10 ether);
            ico.buyTokenWithNative{value: amount}();
        }
        vm.stopPrank();
    }
}
