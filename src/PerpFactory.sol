// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "./libraries/Types.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IMatcher} from "./interfaces/IMatcher.sol";

/// @title PerpFactory
/// @notice Permissionless market creation. Deploys EIP-1167 clones of a PerpMarket
///         implementation — one tx creates a market: pulls LP + insurance seeds
///         (Permit2) and escrows a slashable creator bond (MILESTONE 3). Governance
///         (Safe + timelock) owns global pause and default fee routing.
///
/// STATUS: scaffold — clone wiring, seed pulls, and bond escrow land in MILESTONE 3.
contract PerpFactory {
    address public immutable implementation;
    address public owner; // Safe + timelock in production
    address[] public markets;

    event MarketCreated(
        address indexed market, address indexed collateral, address indexed creator
    );
    event OwnerUpdated(address indexed newOwner);

    error NotImplemented();
    error NotOwner();
    error ZeroAddress();

    constructor(address implementation_, address owner_) {
        if (implementation_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        implementation = implementation_;
        owner = owner_;
    }

    function marketsCount() external view returns (uint256) {
        return markets.length;
    }

    /// @notice MILESTONE 3: clone(implementation) -> initialize -> pull seeds -> escrow bond.
    function createMarket(Types.MarketConfig calldata, IOracleAdapter, IMatcher)
        external
        view
        returns (address)
    {
        _onlyInitialized();
        revert NotImplemented();
    }

    function _onlyInitialized() private view {
        require(implementation != address(0), "no impl");
    }
}
