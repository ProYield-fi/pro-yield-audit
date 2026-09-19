// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeeDistributor {
    IERC20 public pyd;
    address[] public strategies;
    mapping(address => uint256) public pendingFees;
    mapping(address => uint256) public claimed;
    uint256 public totalFees;
    address public owner;
    
    constructor(address _pyd) {
        pyd = IERC20(_pyd);
        owner = msg.sender;
    }

    function addStrategy(address _strategy) external {
        require(msg.sender == owner, "Only owner");
        strategies.push(_strategy);
    }

    function distribute() external {
        for (uint i = 0; i < strategies.length; i++) {
            uint256 fee = pendingFees[strategies[i]];
            pyd.transfer(strategies[i], fee);
            claimed[strategies[i]] += fee;
            totalFees -= fee;
        }
    }

    function withdrawFees() external {
        uint256 amount = pendingFees[msg.sender];
        pendingFees[msg.sender] = 0;
        pyd.transfer(msg.sender, amount);
    }
}
