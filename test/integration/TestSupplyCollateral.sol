// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import "test/helpers/IntegrationTest.sol";

contract TestIntegrationSupplyCollateral is IntegrationTest {
    using WadRayMath for uint256;

    function _boundAmount(uint256 amount) internal view returns (uint256) {
        return bound(amount, 1, type(uint256).max);
    }

    struct SupplyTest {
        uint256 supplied;
        uint256 scaledP2PSupply;
        uint256 scaledPoolSupply;
        uint256 scaledCollateral;
        Types.Indexes256 indexes;
        Types.Market morphoMarket;
    }

    function testShouldSupplyCollateral(uint256 amount, address onBehalf) public returns (SupplyTest memory test) {
        onBehalf = _boundAddressNotZero(onBehalf);

        for (uint256 marketIndex; marketIndex < markets.length; ++marketIndex) {
            _revert();

            TestMarket storage market = testMarkets[markets[marketIndex]];

            amount = _boundSupply(market, amount);

            uint256 balanceBefore = user1.balanceOf(market.underlying);

            user1.approve(market.underlying, amount);

            vm.expectEmit(true, true, true, false, address(morpho));
            emit Events.CollateralSupplied(address(user1), onBehalf, market.underlying, 0, 0);

            test.supplied = user1.supplyCollateral(market.underlying, amount, onBehalf);

            test.indexes = morpho.updatedIndexes(market.underlying);
            test.scaledP2PSupply = morpho.scaledP2PSupplyBalance(market.underlying, onBehalf);
            test.scaledPoolSupply = morpho.scaledPoolSupplyBalance(market.underlying, onBehalf);
            test.scaledCollateral = morpho.scaledCollateralBalance(market.underlying, onBehalf);
            uint256 collateral = test.scaledCollateral.rayMul(test.indexes.supply.poolIndex);

            // Assert balances on Morpho.
            assertEq(test.scaledP2PSupply, 0, "scaledP2PSupply != 0");
            assertEq(test.scaledPoolSupply, 0, "scaledPoolSupply != 0");
            assertEq(test.supplied, amount, "supplied != amount");
            assertApproxLeAbs(collateral, amount, 1, "collateral != amount");

            assertEq(morpho.supplyBalance(market.underlying, onBehalf), 0, "supply != 0");
            assertApproxLeAbs(morpho.collateralBalance(market.underlying, onBehalf), amount, 1, "collateral != amount");

            // Assert Morpho's position on pool.
            assertApproxGeAbs(ERC20(market.aToken).balanceOf(address(morpho)), amount, 1, "morphoSupply != amount");
            assertEq(ERC20(market.debtToken).balanceOf(address(morpho)), 0, "morphoBorrow != 0");

            // Assert user's underlying balance.
            assertEq(
                balanceBefore - user1.balanceOf(market.underlying), amount, "balanceBefore - balanceAfter != amount"
            );

            // Assert Morpho's market state.
            test.morphoMarket = morpho.market(market.underlying);
            assertEq(test.morphoMarket.deltas.supply.scaledDeltaPool, 0, "scaledSupplyDelta != 0");
            assertEq(test.morphoMarket.deltas.supply.scaledTotalP2P, 0, "scaledTotalSupplyP2P != 0");
            assertEq(test.morphoMarket.deltas.borrow.scaledDeltaPool, 0, "scaledBorrowDelta != 0");
            assertEq(test.morphoMarket.deltas.borrow.scaledTotalP2P, 0, "scaledTotalBorrowP2P != 0");
            assertEq(test.morphoMarket.idleSupply, 0, "idleSupply != 0");
        }
    }

    // TODO: should not supply collateral when supply cap reached

    function testShouldUpdateIndexesAfterSupplyCollateral(uint256 amount, address onBehalf) public {
        onBehalf = _boundAddressNotZero(onBehalf);

        for (uint256 marketIndex; marketIndex < markets.length; ++marketIndex) {
            _revert();

            TestMarket storage market = testMarkets[markets[marketIndex]];

            amount = _boundSupply(market, amount);

            Types.Indexes256 memory futureIndexes = morpho.updatedIndexes(market.underlying);

            user1.approve(market.underlying, amount);

            vm.expectEmit(true, true, true, false, address(morpho));
            emit Events.IndexesUpdated(market.underlying, 0, 0, 0, 0);

            user1.supplyCollateral(market.underlying, amount, onBehalf);

            Types.Market memory morphoMarket = morpho.market(market.underlying);
            assertEq(
                morphoMarket.indexes.supply.poolIndex,
                futureIndexes.supply.poolIndex,
                "poolSupplyIndex != futurePoolSupplyIndex"
            );
            assertEq(
                morphoMarket.indexes.borrow.poolIndex,
                futureIndexes.borrow.poolIndex,
                "poolBorrowIndex != futurePoolBorrowIndex"
            );

            assertEq(
                morphoMarket.indexes.supply.p2pIndex,
                futureIndexes.supply.p2pIndex,
                "p2pSupplyIndex != futureP2PSupplyIndex"
            );
            assertEq(
                morphoMarket.indexes.borrow.p2pIndex,
                futureIndexes.borrow.p2pIndex,
                "p2pBorrowIndex != futureP2PBorrowIndex"
            );
        }
    }

    function testShouldRevertSupplyCollateralZero(address onBehalf) public {
        onBehalf = _boundAddressNotZero(onBehalf);

        for (uint256 marketIndex; marketIndex < markets.length; ++marketIndex) {
            vm.expectRevert(Errors.AmountIsZero.selector);
            user1.supplyCollateral(testMarkets[markets[marketIndex]].underlying, 0, onBehalf);
        }
    }

    function testShouldRevertSupplyCollateralOnBehalfZero(uint256 amount) public {
        amount = _boundAmount(amount);

        for (uint256 marketIndex; marketIndex < markets.length; ++marketIndex) {
            vm.expectRevert(Errors.AddressIsZero.selector);
            user1.supplyCollateral(testMarkets[markets[marketIndex]].underlying, amount, address(0));
        }
    }

    function testShouldRevertSupplyCollateralWhenMarketNotCreated(uint256 amount, address onBehalf) public {
        amount = _boundAmount(amount);
        onBehalf = _boundAddressNotZero(onBehalf);

        vm.expectRevert(Errors.MarketNotCreated.selector);
        user1.supplyCollateral(sAvax, amount, onBehalf);
    }

    function testShouldRevertSupplyCollateralWhenSupplyCollateralPaused(uint256 amount, address onBehalf) public {
        amount = _boundAmount(amount);
        onBehalf = _boundAddressNotZero(onBehalf);

        for (uint256 marketIndex; marketIndex < markets.length; ++marketIndex) {
            _revert();

            TestMarket storage market = testMarkets[markets[marketIndex]];

            morpho.setIsSupplyCollateralPaused(market.underlying, true);

            vm.expectRevert(Errors.SupplyCollateralIsPaused.selector);
            user1.supplyCollateral(market.underlying, amount, onBehalf);
        }
    }

    function testShouldSupplyCollateralWhenEverythingElsePaused(uint256 amount, address onBehalf) public {
        amount = _boundAmount(amount);
        onBehalf = _boundAddressNotZero(onBehalf);

        morpho.setIsPausedForAllMarkets(true);

        for (uint256 marketIndex; marketIndex < markets.length; ++marketIndex) {
            _revert();

            TestMarket storage market = testMarkets[markets[marketIndex]];

            amount = _boundSupply(market, amount);

            morpho.setIsSupplyCollateralPaused(market.underlying, false);

            user1.approve(market.underlying, amount);
            user1.supplyCollateral(market.underlying, amount, onBehalf);
        }
    }
}
