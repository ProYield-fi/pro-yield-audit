// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SkyStrategy is BaseStrategy {
    IERC20 public usds;
    uint256 public debtRatio;
    address public skyRegistry;
    
    constructor(address _underlying, address _owner, address _registry) 
        BaseStrategy(_underlying, _owner) 
    {
        usds = IERC20(_underlying);
        skyRegistry = _registry;
        debtRatio = 5000;
    }

    function harvest() external override {
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        totalDebt += address(this).balance;
    }
}
