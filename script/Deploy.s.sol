// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {KingOfTheHill} from "../src/KingOfTheHill.sol";

/// @title Reference deployment of Crown (CRWN) and KingOfTheHill
/// @notice On the network the ProjectFactory performs the real deployment from launch.json: it deploys
///         LaunchToken, then KingOfTheHill with `["$token"]`. This script mirrors that order so the
///         deployment can be rehearsed on a local fork or Anvil. It reads no keys and holds no secrets;
///         the only input is `EXPECTED_CHAIN_ID`, used as a guard against running on the wrong chain.
contract Deploy is Script {
    uint256 public constant SEPOLIA = 11_155_111;
    uint256 public constant ANVIL = 31_337;

    error UnexpectedChain(uint256 expected, uint256 actual);
    error UnsupportedChain(uint256 chainId);

    struct Deployment {
        LaunchToken token;
        KingOfTheHill game;
    }

    /// @notice Entry point for `forge script`. `EXPECTED_CHAIN_ID=0` skips the chain check (dry run only).
    function run() external returns (Deployment memory deployment) {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        checkChain(expected, block.chainid);

        vm.startBroadcast();
        deployment = deploy();
        vm.stopBroadcast();
    }

    /// @notice Refuses to run against any chain other than the target (Sepolia) or a local Anvil fork.
    function checkChain(uint256 expected, uint256 actual) public pure {
        if (expected != 0 && expected != actual) revert UnexpectedChain(expected, actual);
        if (expected != 0 && expected != SEPOLIA && expected != ANVIL) revert UnsupportedChain(expected);
    }

    /// @notice Deploys the token, then the game bound to it: the same order and arguments as launch.json.
    function deploy() public returns (Deployment memory deployment) {
        deployment.token = new LaunchToken();
        deployment.game = new KingOfTheHill(address(deployment.token));
    }
}
