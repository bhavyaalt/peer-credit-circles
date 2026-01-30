// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PoolFactory.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy PoolFactory
        PoolFactory factory = new PoolFactory();
        
        console.log("PoolFactory deployed at:", address(factory));
        
        vm.stopBroadcast();
    }
}
