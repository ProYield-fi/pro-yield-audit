// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";

contract MorphoStrategy is BaseStrategy {
    address public morpho;
    uint256 public totalSupply;

    constructor(address _underlying, address _owner) BaseStrategy(_underlying, _owner) {}

    function setMorpho(address _morpho) external onlyOwner {
        morpho = _morpho;
    }

    function supply(uint256 amount) external {
        morpho = msg.sender;
        totalSupply += amount;
    }

    function withdraw(uint256 amount) external override {
        totalSupply -= amount;
    }

    function harvest() external override {
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        lastHarvest = block.timestamp;
    }
}
