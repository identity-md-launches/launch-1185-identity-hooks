// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IHOOKSToken} from "../src/IHOOKSToken.sol";

/// @notice Deploys IHOOKSToken. The token has no configuration: its name, symbol and supply are
/// fixed in the contract, and the whole supply goes to whoever deploys it. `deploy()` holds the
/// logic so tests call it directly; `run()` only wraps it in a broadcast.
/// @dev On the launch this script is not used: the factory deploys the token from its creation
/// code and receives the supply. The script exists for reviewable local or test-net deployments.
contract DeployIHOOKS is Script {
    function deploy() public returns (IHOOKSToken token) {
        token = new IHOOKSToken();
    }

    function run() external returns (IHOOKSToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
