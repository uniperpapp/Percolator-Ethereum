// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {Constants} from "../libraries/Constants.sol";

/// @title PushOracleAdapter
/// @notice Simplest concrete oracle: a trusted authority pushes the raw target price.
///         Useful for tests, bootstrapping, and the keeper-signed Phase-2 mark. Production
///         long-tail markets use the Uniswap-TWAP adapter; majors use a Chainlink adapter.
///         The market still applies the §1.7 staircase + envelope on top of whatever this
///         returns, so a bad push cannot be marked through in one step.
contract PushOracleAdapter is IOracleAdapter {
    address public authority;
    uint256 public priceE6;
    uint64 public publishTs;
    uint64 public maxStalenessSec;

    event AuthorityUpdated(address indexed newAuthority);
    event PricePushed(uint256 priceE6, uint64 publishTs);

    error NotAuthority();
    error InvalidPrice();
    error Stale();
    error ZeroAddress();

    constructor(address authority_, uint64 maxStalenessSec_) {
        if (authority_ == address(0)) revert ZeroAddress();
        authority = authority_;
        maxStalenessSec = maxStalenessSec_;
    }

    function setAuthority(address newAuthority) external {
        if (msg.sender != authority) revert NotAuthority();
        if (newAuthority == address(0)) revert ZeroAddress();
        authority = newAuthority;
        emit AuthorityUpdated(newAuthority);
    }

    function pushPrice(uint256 priceE6_) external {
        if (msg.sender != authority) revert NotAuthority();
        if (priceE6_ == 0 || priceE6_ > Constants.MAX_ORACLE_PRICE) revert InvalidPrice();
        priceE6 = priceE6_;
        publishTs = uint64(block.timestamp);
        emit PricePushed(priceE6_, publishTs);
    }

    /// @inheritdoc IOracleAdapter
    function readTarget() external view returns (uint256, uint64) {
        if (priceE6 == 0) revert InvalidPrice();
        if (maxStalenessSec != 0 && block.timestamp > uint256(publishTs) + maxStalenessSec) {
            revert Stale();
        }
        return (priceE6, publishTs);
    }
}
