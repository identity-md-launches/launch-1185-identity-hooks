# identity hooks (IHOOKS)

A fixed-supply ERC-20 token for the IdentityMD custom-token launch on Ethereum.

| Field | Value |
| --- | --- |
| Solidity contract | `IHOOKSToken` (`src/IHOOKSToken.sol`) |
| Token name | `identity hooks` |
| Token symbol | `IHOOKS` |
| Decimals | 18 |
| Total supply | 1,000,000,000 IHOOKS = `1000000000000000000000000000` minor units |
| Minting | Once, in the constructor, all of it to `msg.sender` (the deployer) |
| Constructor arguments | None |
| Owner / admin | None |

## Behaviour

- The constructor mints the whole supply to whoever deploys the contract and emits a single
  `Transfer(address(0), deployer, supply)` event. Nothing can mint afterwards: there is no `mint`,
  no minter role and no owner.
- Transfers are plain OpenZeppelin ERC-20 transfers. There is no fee, no burn on transfer, no
  reflection, no pause, no blocklist and no transfer limit. Every transfer moves exactly the amount
  requested, so the launch flows (factory to distributor, distributor to claimants, factory to the
  Uniswap v4 PoolManager, and swaps in either direction) arrive whole.
- `transferFrom` requires an allowance set by the holder. Nobody, the deployer included, can move
  or freeze another holder's balance.
- The contract holds no ETH and has no `receive` or `fallback`.
- The runtime code contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and there is no
  proxy, no upgrade path and no external library (OpenZeppelin's code is inlined).

## Assumptions

- The brief asks for a plain token: name, symbol, supply and a single mint to the deployer. No
  tax, burn, vesting, governance or ownership feature was requested, so none was added. A plain
  token also satisfies the launch floor without any exemption list.
- On the launch, the deployer is the `ProjectFactory`, which calls the creation code through
  CREATE2. The factory therefore receives the full supply and pays all of it out: 10% to the
  launch's MerkleDistributor, 80% to the single-sided Uniswap v4 pool, and the remaining 10% to the
  requester's `remainderTo` address. The token does not need, and does not take, the factory,
  PoolManager or launch-number arguments because it exempts nothing.
- The launch records the contract under its Solidity identifier, `IHOOKSToken` (11 characters,
  within the 32-character limit). The token's `name()` is `identity hooks`.

## Deployment parameters

The launch decides these; they are listed for the manifest step and are not open questions.

| Parameter | Value |
| --- | --- |
| Chain | Ethereum, chain id 1 |
| `token.contract` | `IHOOKSToken` |
| `token.name` / `token.symbol` / `token.decimals` | `identity hooks` / `IHOOKS` / 18 |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `pool.pairedCurrency` | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| `pool.fee` | 12500 (1.25%) |
| `pool.tickSpacing` | 60 |
| `pool.initialPrice` | `79228162514264337593543950336` (provenance only; the deployer derives the opening price) |
| `economics.poolBps` | 8000 |
| `economics.initialMarketCapWei` | `2640000000000000000000` (2,640 IMD for the whole supply) |
| `economics.remainderTo` | `0x419c3cee9568cfa394d7cf39d59ae49c968e7405` |
| Application contracts | None |

`launch.json` is written by the manifest step after acceptance; it is deliberately not in this
repository.

Build settings that the launch reproduces from `foundry.toml`: `solc = "0.8.26"`,
`evm_version = "cancun"`, optimizer on with 200 runs, `via_ir = false`, `bytecode_hash = "none"`.

## After launch

There is nothing to configure. The token has no owner-set values, no setters and no privileged
functions.

## Operational responsibilities

- **Deployer / factory.** Receives the whole supply at construction and must forward it according
  to the launch economics. The token itself does not enforce the split.
- **Requester.** Owns whatever arrives at `remainderTo`. No key held by the requester can change
  the token afterwards, which is the trust model: there is nothing to misuse, and nothing to fix
  on-chain if a bug is found. A new token would have to be deployed.
- **Explorer verification.** After deployment, verify the source with `forge verify-contract`
  using the same `foundry.toml` settings. This belongs to the network's deployer, not this task.
- **Audit.** Passing tests are not an audit. The contract is a thin wrapper over OpenZeppelin
  ERC20 v5.4.0 with no custom logic, but an independent adversarial review before release remains
  the launch's responsibility.

## Local deployment

`script/DeployIHOOKS.s.sol` exposes `deploy()` (tested directly) and a `run()` wrapper that
broadcasts with whatever signer `forge script` is given. It reads no environment variables. The
launch does not use this script; it deploys the token from its bytecode.

```bash
forge script script/DeployIHOOKS.s.sol:DeployIHOOKS --rpc-url <rpc> --broadcast --sender <addr>
```

## Repository layout

- `src/IHOOKSToken.sol` — the token.
- `test/IHOOKSToken.t.sol` — unit, failure, launch-flow, privilege-probe, opcode and fuzz tests.
- `script/DeployIHOOKS.s.sol` — deploy script.
- `lib/forge-std` (v1.9.7) and `lib/openzeppelin-contracts` (v5.4.0) — vendored as ordinary
  files, no submodules, so the project builds offline.
- `foundry.toml`, `remappings.txt` — pinned compiler 0.8.26, `bytecode_hash = "none"`, `ffi` off,
  no filesystem permissions.

## Checks

```bash
forge build
forge test
forge fmt --check
```

Tests use no environment variables and no fixed caller, so they pass in any order and in parallel.
Slither and Mythril were not run: they are not part of this task's toolchain.
