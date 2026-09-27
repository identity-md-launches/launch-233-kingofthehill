// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Crown (CRWN) launch token
/// @notice Fixed-supply ERC-20. The whole supply of 1,000,000,000 CRWN (10^27 minor units, 18 decimals)
///         is minted once, in the constructor, to `msg.sender`, which is the project factory at launch.
/// @dev No constructor arguments, no owner, no mint, no burn hook, no pause, no blocklist, no fee and no
///      upgrade path. Everything after deployment is plain ERC-20 behaviour inherited from OpenZeppelin.
contract LaunchToken is ERC20 {
    /// @notice Total supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Crown", "CRWN") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
