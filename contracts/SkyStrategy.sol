// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
using SafeERC20 for IERC20;
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
using SafeERC20 for IERC20;

contract SkyStrategy is BaseStrategy {
    IERC20 public usds;
    uint256 public debtRatio;
    address public skyRegistry;

    constructor(address _underlying, address _owner, address _registry)
        BaseStrategy(_underlying, _owner, "Sky")
    {
        usds = IERC20(_underlying);
        skyRegistry = _registry;
        debtRatio = 5000;
    }

    function _doHarvest() internal override returns (uint256) {
        uint256 profit = 0;
        if (address(this).balance > 0) {
            uint256 balance = address(this).balance;
            totalDebt += balance;
            (bool success, ) = msg.sender.call{value: balance}("");
            require(success, "Sky: transfer failed");
            profit = balance;
        }
        return profit;
    }
}
