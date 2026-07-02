// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {WorldCupBetting} from "../src/WorldCupBetting.sol";
import {ReputationSystem} from "../src/ReputationSystem.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Foundry port of the Hardhat assessment scenarios (A–I) for WorldCupBetting.
/// @dev The test contract deploys everything, so it is the Ownable owner of both the market and the
///      MockERC20 (mirroring `owner`/deployer in the Hardhat fixture). `receive()` lets it collect
///      withdrawn ETH fees.
contract WorldCupBettingTest is Test {
    WorldCupBetting internal market;
    ReputationSystem internal reputation;
    MockERC20 internal usdc;

    address internal oracle = makeAddr("oracle");
    address internal fanBrazil = makeAddr("fanBrazil");
    address internal fanSerbia = makeAddr("fanSerbia");
    address internal fanDraw = makeAddr("fanDraw");
    address internal fanFrance = makeAddr("fanFrance");
    address internal fanSpain = makeAddr("fanSpain");
    address internal neutralFan = makeAddr("neutralFan");

    receive() external payable {}

    function setUp() public {
        reputation = new ReputationSystem();
        market = new WorldCupBetting(address(reputation));
        reputation.setPredictionMarket(address(market));
        usdc = new MockERC20("Mock USDC", "mUSDC");
    }

    function _threeWay() internal pure returns (string[] memory o) {
        o = new string[](3);
        o[0] = "Brazil";
        o[1] = "Draw";
        o[2] = "Serbia";
    }

    function _yesNo() internal pure returns (string[] memory o) {
        o = new string[](2);
        o[0] = "YES";
        o[1] = "NO";
    }

    // Scenario A: 1X2 market can be created and resolved; status reads as Resolved (==2).
    function test_ScenarioA_createAndResolveThreeWay() public {
        uint256 resolution = block.timestamp + 7 days;
        market.createMarket("Brazil vs Serbia?", "full-time result", _threeWay(), resolution, oracle, address(0));

        uint256 marketId = market.marketCount();
        assertEq(marketId, 1);

        uint256 betDraw = 0.2 ether;
        vm.deal(fanDraw, betDraw);
        vm.prank(fanDraw);
        market.placeBet{value: betDraw}(marketId, 1, betDraw, 0);

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(marketId, 1);

        (,,,,,,, WorldCupBetting.MarketStatus status,,) = market.getMarket(marketId);
        assertEq(uint256(status), 2);
    }

    // Scenario B: winner receives net payout after 2% fee; owner withdraws ETH fees.
    function test_ScenarioB_winnerNetPayoutAndFeeWithdraw() public {
        uint256 resolution = block.timestamp + 86400;
        market.createMarket(
            "France eliminate Spain?", "YES if France advances", _yesNo(), resolution, oracle, address(0)
        );

        uint256 marketId = market.marketCount();
        uint256 stake = 1 ether;

        vm.deal(fanFrance, stake);
        vm.prank(fanFrance);
        market.placeBet{value: stake}(marketId, 0, stake, 0);

        vm.deal(fanSpain, stake);
        vm.prank(fanSpain);
        market.placeBet{value: stake}(marketId, 1, stake, 0);

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(marketId, 0);

        uint256 yesBetId = market.getMarketBets(marketId)[0];

        uint256 balBefore = fanFrance.balance;
        vm.prank(fanFrance);
        market.claimWinnings(yesBetId);
        assertGt(fanFrance.balance, balBefore);

        uint256 fees = market.getAvailableFees(address(0));
        assertGt(fees, 0);

        uint256 ownerBefore = address(this).balance;
        market.withdrawFees(address(0));
        assertGt(address(this).balance, ownerBefore);
    }

    // Scenario C: cannot resolve before resolutionTime.
    function test_ScenarioC_cannotResolveTooEarly() public {
        uint256 resolution = block.timestamp + 3600;
        market.createMarket("Who lifts the trophy?", "winner", _yesNo(), resolution, oracle, address(0));

        uint256 marketId = market.marketCount();
        vm.prank(oracle);
        vm.expectRevert(bytes("Too early"));
        market.resolveMarket(marketId, 0);
    }

    // Scenario D: only the arbitrator can resolve.
    function test_ScenarioD_onlyArbitratorResolves() public {
        uint256 resolution = block.timestamp + 60;
        market.createMarket("Host reach semis?", "YES/NO", _yesNo(), resolution, oracle, address(0));

        uint256 marketId = market.marketCount();
        vm.warp(resolution + 1);
        vm.prank(neutralFan);
        vm.expectRevert(bytes("Only arbitrator"));
        market.resolveMarket(marketId, 0);
    }

    // Scenario E: no new bets at/after resolutionTime.
    function test_ScenarioE_noBetsAfterClose() public {
        uint256 resolution = block.timestamp + 120;
        market.createMarket("Golden boot over 6?", "YES/NO", _yesNo(), resolution, oracle, address(0));

        uint256 marketId = market.marketCount();
        vm.warp(resolution);

        uint256 stake = 0.05 ether;
        vm.deal(fanBrazil, stake);
        vm.prank(fanBrazil);
        vm.expectRevert(bytes("Market closed"));
        market.placeBet{value: stake}(marketId, 0, stake, 0);
    }

    // Scenario F: slippage guard rejects when minShares is too high.
    function test_ScenarioF_slippageGuard() public {
        uint256 resolution = block.timestamp + 86400;
        market.createMarket("VAR overturn a goal?", "YES/NO", _yesNo(), resolution, oracle, address(0));

        uint256 marketId = market.marketCount();
        uint256 stake = 0.1 ether;
        vm.deal(fanBrazil, stake);
        vm.prank(fanBrazil);
        vm.expectRevert(bytes("Slippage exceeded"));
        market.placeBet{value: stake}(marketId, 0, stake, type(uint256).max);
    }

    // Scenario G: secondary market — buyer collects if the seller picked the winner.
    function test_ScenarioG_secondaryMarketBuyerClaims() public {
        uint256 resolution = block.timestamp + 86400;
        market.createMarket("Underdog win opener?", "YES/NO", _yesNo(), resolution, oracle, address(0));

        uint256 marketId = market.marketCount();
        uint256 stake = 0.5 ether;

        vm.deal(fanBrazil, stake);
        vm.prank(fanBrazil);
        market.placeBet{value: stake}(marketId, 0, stake, 0);

        uint256[] memory betIds = market.getUserBets(fanBrazil);
        uint256 betId = betIds[betIds.length - 1];

        uint256 listPrice = 0.55 ether;
        vm.prank(fanBrazil);
        market.listPosition(betId, listPrice);

        vm.deal(neutralFan, listPrice);
        vm.prank(neutralFan);
        market.buyPosition{value: listPrice}(betId);

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(marketId, 0);

        uint256 before = neutralFan.balance;
        vm.prank(neutralFan);
        market.claimWinnings(betId);
        assertGt(neutralFan.balance, before);
    }

    // Scenario H: same lifecycle using ERC20 collateral.
    function test_ScenarioH_erc20Lifecycle() public {
        uint256 resolution = block.timestamp + 86400;
        market.createMarket("Total goals over 170?", "YES/NO", _yesNo(), resolution, oracle, address(usdc));

        uint256 marketId = market.marketCount();
        uint256 amount = 100 ether; // 100 * 1e18

        usdc.mint(fanFrance, amount);
        usdc.mint(fanSpain, amount);

        vm.prank(fanFrance);
        usdc.approve(address(market), amount);
        vm.prank(fanSpain);
        usdc.approve(address(market), amount);

        vm.prank(fanFrance);
        market.placeBet(marketId, 0, amount / 2, 0);
        vm.prank(fanSpain);
        market.placeBet(marketId, 1, amount / 2, 0);

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(marketId, 0);

        uint256 franceBetId = market.getMarketBets(marketId)[0];

        uint256 balBefore = usdc.balanceOf(fanFrance);
        vm.prank(fanFrance);
        market.claimWinnings(franceBetId);
        assertGt(usdc.balanceOf(fanFrance), balBefore);
    }

    // Scenario I: losing side settles for reputation and cannot double-claim.
    function test_ScenarioI_losingClaimNoDoubleClaim() public {
        uint256 resolution = block.timestamp + 86400;
        market.createMarket("Penalty shootout in final?", "YES/NO", _yesNo(), resolution, oracle, address(0));

        uint256 marketId = market.marketCount();
        uint256 stake = 0.02 ether;

        vm.deal(fanBrazil, stake);
        vm.prank(fanBrazil);
        market.placeBet{value: stake}(marketId, 0, stake, 0);

        uint256 betId = market.getMarketBets(marketId)[0];

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(marketId, 1); // outcome 0 loses

        uint256 ethBefore = fanBrazil.balance;
        vm.prank(fanBrazil);
        market.claimWinnings(betId);
        assertLe(fanBrazil.balance, ethBefore);

        vm.prank(fanBrazil);
        vm.expectRevert(bytes("Already claimed"));
        market.claimWinnings(betId);
    }
}
