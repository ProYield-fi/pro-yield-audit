// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Funding-rate oracle interface for delta-neutral strategies.
/// Rate is in basis points, ANNUALIZED (10000 = 100% APR).
interface IFundingOracle {
    function getFundingRate() external view returns (uint256);
}

/// @notice Testnet funding oracle — operator sets the rate that the real
/// venue would publish. Production swaps in a Hyperliquid rate adapter
/// (keeper-signed or via the HL EVM precompiles when available).
contract MockFundingOracle is IFundingOracle {
    uint256 public rate; // annualized bps
    address public immutable owner;

    event RateSet(uint256 rate);

    constructor(uint256 initialRateBps) {
        owner = msg.sender;
        rate = initialRateBps;
    }

    function setRate(uint256 rateBps) external {
        require(msg.sender == owner, "MockFundingOracle: not owner");
        rate = rateBps;
        emit RateSet(rateBps);
    }

    function getFundingRate() external view override returns (uint256) {
        return rate;
    }
}
