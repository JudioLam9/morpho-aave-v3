// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {SupplyVaultBase} from "src/extensions/SupplyVaultBase.sol";

contract SupplyVaultBaseMock is SupplyVaultBase {
    constructor(address _morpho, address _recipient) SupplyVaultBase(_morpho, _recipient) {}
}
