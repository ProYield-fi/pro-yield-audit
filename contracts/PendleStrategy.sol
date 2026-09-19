// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";

contract PendleStrategy is BaseStrategy {
    address public pendleMarket;
    uint256 public maturity;
    uint256 public pyTokenAmount;
    
    struct Position {
        uint256 amount;
        uint256 expiry;
        bool exists;
    }
    mapping(address => Position) public positions;

    constructor(address _underlying, address _owner) BaseStrategy(_underlying, _owner) {
        maturity = block.timestamp + 365 days;
    }

    function setMarket(address _market) external onlyOwner {
        pendleMarket = _market;
    }

    function harvest() external override nonReentrant {
        if (block.timestamp > maturity) {
            _claimRewards();
        }
    }

    function _claimRewards() internal nonReentrant {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = pendleMarket.call{value: balance}("");
            require(success, "Pendle: transfer failed");
        }
    }
}
