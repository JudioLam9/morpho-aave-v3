// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {TestHelpers} from "./helpers/TestHelpers.sol";
import {TestConfig} from "./helpers/TestConfig.sol";

import {TestSetup} from "./setup/TestSetup.sol";
import {console2} from "@forge-std/console2.sol";

import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";
import {ThreeHeapOrdering} from "@morpho-data-structures/ThreeHeapOrdering.sol";

import {SafeTransferLib, ERC20} from "@solmate/utils/SafeTransferLib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IPool, IPoolAddressesProvider} from "../src/interfaces/aave/IPool.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";
import {DataTypes} from "../src/libraries/aave/DataTypes.sol";
import {ReserveConfiguration} from "../src/libraries/aave/ReserveConfiguration.sol";

import {MatchingEngine} from "../src/MatchingEngine.sol";
import {MorphoInternal} from "../src/MorphoInternal.sol";
import {MorphoStorage} from "../src/MorphoStorage.sol";
import {Types} from "../src/libraries/Types.sol";
import {MarketLib} from "../src/libraries/MarketLib.sol";
import {MarketBalanceLib} from "../src/libraries/MarketBalanceLib.sol";
import {PoolLib} from "../src/libraries/PoolLib.sol";
import {Math} from "@morpho-utils/math/Math.sol";

contract TestMatchingEngine is TestSetup, MatchingEngine {
    using MarketLib for Types.Market;
    using MarketBalanceLib for Types.MarketBalances;
    using PoolLib for IPool;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using SafeTransferLib for ERC20;
    using ThreeHeapOrdering for ThreeHeapOrdering.HeapArray;
    using TestConfig for TestConfig.Config;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Math for uint256;

    constructor() TestSetup() MorphoStorage(config.load(vm.envString("NETWORK")).getAddress("addressesProvider")) {}

    function setUp() public virtual override {
        super.setUp();
        _market[dai].setIndexes(
            Types.Indexes256(
                Types.MarketSideIndexes256(WadRayMath.RAY, WadRayMath.RAY),
                Types.MarketSideIndexes256(WadRayMath.RAY, WadRayMath.RAY)
            )
        );
        _maxSortedUsers = 10;
    }

    function testPromote(
        uint256 poolBalance,
        uint256 p2pBalance,
        uint256 poolIndex,
        uint256 p2pIndex,
        uint256 remaining
    ) public {
        poolBalance = bound(poolBalance, 0, type(uint96).max);
        p2pBalance = bound(p2pBalance, 0, type(uint96).max);
        poolIndex = bound(poolIndex, WadRayMath.RAY, WadRayMath.RAY * 1_000);
        p2pIndex = bound(p2pIndex, WadRayMath.RAY, WadRayMath.RAY * 1_000);
        remaining = bound(remaining, 0, type(uint96).max);

        uint256 toProcess = Math.min(poolBalance.rayMul(poolIndex), remaining);

        (uint256 newPoolBalance, uint256 newP2PBalance, uint256 newRemaining) =
            _promote(poolBalance, p2pBalance, Types.MarketSideIndexes256(poolIndex, p2pIndex), remaining);

        assertEq(newPoolBalance, poolBalance - toProcess.rayDiv(poolIndex));
        assertEq(newP2PBalance, p2pBalance + toProcess.rayDiv(p2pIndex));
        assertEq(newRemaining, remaining - toProcess);
    }

    function testDemote(uint256 poolBalance, uint256 p2pBalance, uint256 poolIndex, uint256 p2pIndex, uint256 remaining)
        public
    {
        poolBalance = bound(poolBalance, 0, type(uint96).max);
        p2pBalance = bound(p2pBalance, 0, type(uint96).max);
        poolIndex = bound(poolIndex, WadRayMath.RAY, WadRayMath.RAY * 1_000);
        p2pIndex = bound(p2pIndex, WadRayMath.RAY, WadRayMath.RAY * 1_000);
        remaining = bound(remaining, 0, type(uint96).max);

        uint256 toProcess = Math.min(p2pBalance.rayMul(p2pIndex), remaining);

        (uint256 newPoolBalance, uint256 newP2PBalance, uint256 newRemaining) =
            _demote(poolBalance, p2pBalance, Types.MarketSideIndexes256(poolIndex, p2pIndex), remaining);

        assertEq(newPoolBalance, poolBalance + toProcess.rayDiv(poolIndex));
        assertEq(newP2PBalance, p2pBalance - toProcess.rayDiv(p2pIndex));
        assertEq(newRemaining, remaining - toProcess);
    }

    function testPromoteSuppliers(uint256 numSuppliers, uint256 amountToMatch, uint256 maxLoops) public {
        numSuppliers = bound(numSuppliers, 0, 10);
        amountToMatch = bound(amountToMatch, 0, 20e18);
        maxLoops = bound(maxLoops, 0, numSuppliers);

        Types.MarketBalances storage marketBalances = _marketBalances[dai];

        for (uint256 i; i < numSuppliers; i++) {
            _updateSupplierInDS(dai, address(uint160(i + 1)), 1e18, 0);
        }

        (uint256 promoted, uint256 loopsDone) = _promoteSuppliers(dai, amountToMatch, maxLoops);

        uint256 totalP2PSupply;
        for (uint256 i; i < numSuppliers; i++) {
            address user = address(uint160(i + 1));
            assertEq(
                marketBalances.scaledPoolSupplyBalance(user) + marketBalances.scaledP2PSupplyBalance(user),
                1e18,
                "user supply"
            );
            totalP2PSupply += marketBalances.scaledP2PSupplyBalance(user);
        }

        uint256 expectedPromoted = Math.min(amountToMatch, maxLoops * 1e18);
        expectedPromoted = Math.min(expectedPromoted, numSuppliers * 1e18);

        uint256 expectedLoops = Math.min(expectedPromoted.divUp(1e18), maxLoops);

        assertEq(promoted, expectedPromoted, "promoted");
        assertEq(totalP2PSupply, promoted, "total borrow");
        assertEq(loopsDone, expectedLoops, "loops");
    }

    function testPromoteBorrowers(uint256 numBorrowers, uint256 amountToMatch, uint256 maxLoops) public {
        numBorrowers = bound(numBorrowers, 0, 10);
        amountToMatch = bound(amountToMatch, 0, 20e18);
        maxLoops = bound(maxLoops, 0, numBorrowers);

        Types.MarketBalances storage marketBalances = _marketBalances[dai];

        for (uint256 i; i < numBorrowers; i++) {
            _updateBorrowerInDS(dai, address(uint160(i + 1)), 1e18, 0);
        }

        (uint256 promoted, uint256 loopsDone) = _promoteBorrowers(dai, amountToMatch, maxLoops);

        uint256 totalP2PBorrow;
        for (uint256 i; i < numBorrowers; i++) {
            address user = address(uint160(i + 1));
            assertEq(
                marketBalances.scaledPoolBorrowBalance(user) + marketBalances.scaledP2PBorrowBalance(user),
                1e18,
                "user borrow"
            );
            totalP2PBorrow += marketBalances.scaledP2PBorrowBalance(user);
        }

        uint256 expectedPromoted = Math.min(amountToMatch, maxLoops * 1e18);
        expectedPromoted = Math.min(expectedPromoted, numBorrowers * 1e18);

        uint256 expectedLoops = Math.min(expectedPromoted.divUp(1e18), maxLoops);

        assertEq(promoted, expectedPromoted, "promoted");
        assertEq(totalP2PBorrow, promoted, "total borrow");
        assertEq(loopsDone, expectedLoops, "loops");
    }

    function testDemoteSuppliers(uint256 numSuppliers, uint256 amountToMatch, uint256 maxLoops) public {
        numSuppliers = bound(numSuppliers, 0, 10);
        amountToMatch = bound(amountToMatch, 0, 20e18);
        maxLoops = bound(maxLoops, 0, numSuppliers);

        Types.MarketBalances storage marketBalances = _marketBalances[dai];

        for (uint256 i; i < numSuppliers; i++) {
            _updateSupplierInDS(dai, address(uint160(i + 1)), 0, 1e18);
        }

        uint256 demoted = _demoteSuppliers(dai, amountToMatch, maxLoops);

        uint256 totalP2PSupply;
        for (uint256 i; i < numSuppliers; i++) {
            address user = address(uint160(i + 1));
            assertEq(
                marketBalances.scaledPoolSupplyBalance(user) + marketBalances.scaledP2PSupplyBalance(user),
                1e18,
                "user supply"
            );
            totalP2PSupply += marketBalances.scaledP2PSupplyBalance(user);
        }

        uint256 expectedDemoted = Math.min(amountToMatch, maxLoops * 1e18);
        expectedDemoted = Math.min(expectedDemoted, numSuppliers * 1e18);

        assertEq(demoted, expectedDemoted, "demoted");
        assertEq(totalP2PSupply, 1e18 * numSuppliers - demoted, "total borrow");
    }

    function testDemoteBorrowers(uint256 numBorrowers, uint256 amountToMatch, uint256 maxLoops) public {
        numBorrowers = bound(numBorrowers, 0, 10);
        amountToMatch = bound(amountToMatch, 0, 20e18);
        maxLoops = bound(maxLoops, 0, numBorrowers);

        Types.MarketBalances storage marketBalances = _marketBalances[dai];

        for (uint256 i; i < numBorrowers; i++) {
            _updateBorrowerInDS(dai, address(uint160(i + 1)), 0, 1e18);
        }

        uint256 demoted = _demoteBorrowers(dai, amountToMatch, maxLoops);

        uint256 totalP2PBorrow;
        for (uint256 i; i < numBorrowers; i++) {
            address user = address(uint160(i + 1));
            assertEq(
                marketBalances.scaledPoolBorrowBalance(user) + marketBalances.scaledP2PBorrowBalance(user),
                1e18,
                "user borrow"
            );
            totalP2PBorrow += marketBalances.scaledP2PBorrowBalance(user);
        }

        uint256 expectedDemoted = Math.min(amountToMatch, maxLoops * 1e18);
        expectedDemoted = Math.min(expectedDemoted, numBorrowers * 1e18);

        assertEq(demoted, expectedDemoted, "demoted");
        assertEq(totalP2PBorrow, 1e18 * numBorrowers - demoted, "total borrow");
    }
}
