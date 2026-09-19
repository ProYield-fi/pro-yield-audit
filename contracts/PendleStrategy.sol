// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
using SafeERC20 for IERC20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PendleStrategy is BaseStrategy {
    address public pendleMarket;
    uint256 public maturity;
    uint256 public pyTokenAmount;

    constructor(address _underlying, address _owner, address _pendleMarket)
        BaseStrategy(_underlying, _owner, "Pendle")
    {
        pendleMarket = _pendleMarket;
        maturity = block.timestamp + 365 days;
    }

    function name() external view override returns (string memory) {
        return "Pendle";
    }

    function setMarket(address _market) external onlyOwner nonReentrant {
        pendleMarket = _market;
    }

    function harvest() external override nonReentrant {
        if (block.timestamp > maturity) {
            _claimRewards();
        }
    }

    function _claimRewards() internal nonReentrant {
        if (pendleMarket != address(0) && address(this).balance > 0) {
            (bool success, ) = pendleMarket.call{value: address(this).balance}("");
            require(success, "Pendle: transfer failed");
        }
    }

    function _doHarvest() internal override returns (uint256) {
        uint256 profit = 0;
        _claimRewards();
        return profit;
    }
}
