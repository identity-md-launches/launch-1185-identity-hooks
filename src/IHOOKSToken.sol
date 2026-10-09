// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title identity hooks (IHOOKS)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 IHOOKS (18 decimals) is minted
/// once, in the constructor, to the deployer. There is no owner, no minter, no pause, no blocklist,
/// no fee and no burn hook: every transfer moves exactly the amount asked for, and the supply can
/// never grow after deployment.
/// @dev The contract identifier is `IHOOKSToken` (the launch records it under this name); the
/// token's own name and symbol are what `name()` and `symbol()` return. The constructor takes no
/// arguments and makes no external calls, so it deploys on an empty chain. On the launch the
/// deployer is the ProjectFactory, which receives the supply and pays all of it out.
contract IHOOKSToken is ERC20 {
    /// @notice Total supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("identity hooks", "IHOOKS") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
