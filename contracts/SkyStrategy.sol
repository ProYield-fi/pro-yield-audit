// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SkyStrategy is BaseStrategy {
    IERC20 public immutable usds;
    uint256 public immutable debtRatio;
    address public immutable skyRegistry;

    constructor(address _underlying, address initialOwner, address _registry)
        BaseStrategy(_underlying, initialOwner, "Sky")
    {
        usds = IERC20(_underlying);
        require(_registry != address(0), "Sky: zero registry");
        skyRegistry = _registry;
        debtRatio = 5000;
    }

    function name() external view override returns (string memory) {
        return "Sky";
    }

    function _doHarvest() internal override returns (uint256) {
        uint256 profit = 0;
        if (address(this).balance > 0 && isActive && msg.sender == owner()) {
            uint256 balance = address(this).balance;
            totalDebt += balance;
            uint256 _bal = balance;
            // slither-disable-next-line low-level-calls
            (bool success, ) = msg.sender.call{value: balance}("");
            require(success, "Sky: transfer failed");
            profit = balance;
        }
        return profit;
    }
}
