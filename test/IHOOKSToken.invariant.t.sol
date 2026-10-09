// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IHOOKSToken} from "../src/IHOOKSToken.sol";

/// @notice Drives IHOOKSToken with random call sequences from a fixed set of actors and keeps
/// ghost accounting of what every address should hold and what every allowance should be.
/// @dev Two layers, as the fizz handler guide lays out. The clamped handlers bound amounts so the
/// call must succeed and check its postconditions. The unclamped handlers pass raw amounts and
/// check that the call fails exactly when, and with exactly the error, the ERC-20 rules demand,
/// and that a failed call changes nothing. Every assertion failure reverts the handler call, and the
/// suite runs with fail-on-revert, so an unexpected revert anywhere is a failed test.
contract IHOOKSHandler is Test {
    IHOOKSToken public immutable token;

    /// @dev Addresses that can send: the deployer, which starts with the supply, and five holders.
    address[] internal actors;
    /// @dev Addresses that can receive: the actors plus the token contract itself, a sink that can
    /// never send again. Tokens sent there must still be counted, not vanish.
    address[] internal recipients;

    mapping(address => uint256) public initialBalance;
    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostSent;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostTransfers;
    uint256 public ghostRejectedTransfers;
    uint256 public ghostApprovals;
    uint256 public ghostTransferFroms;
    uint256 public ghostRejectedTransferFroms;
    uint256 public ghostAdminProbes;
    uint256 public ghostEtherProbes;

    string[22] internal adminSignatures = [
        "mint(address,uint256)",
        "mint(uint256)",
        "mint()",
        "issue(uint256)",
        "setOwner(address)",
        "transferOwnership(address)",
        "upgradeTo(address)",
        "initialize(address)",
        "unpause()",
        "setMinter(address)",
        "pause()",
        "blacklist(address)",
        "blocklist(address)",
        "freeze(address)",
        "freezeAccount(address)",
        "setBlacklist(address,bool)",
        "setBlocked(address,bool)",
        "lock(address)",
        "disableTransfers()",
        "setTransfersEnabled(bool)",
        "burnFrom(address,uint256)",
        "seize(address)"
    ];

    constructor(IHOOKSToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        actors.push(makeAddr("holder1"));
        actors.push(makeAddr("holder2"));
        actors.push(makeAddr("holder3"));
        actors.push(makeAddr("holder4"));
        actors.push(makeAddr("holder5"));
        for (uint256 i; i < actors.length; ++i) {
            recipients.push(actors[i]);
        }
        recipients.push(address(token_));
        for (uint256 i; i < recipients.length; ++i) {
            initialBalance[recipients[i]] = token_.balanceOf(recipients[i]);
        }
    }

    // ---------------------------------------------------------------- views for the invariants

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function recipientAt(uint256 i) external view returns (address) {
        return recipients[i];
    }

    // ---------------------------------------------------------------- clamped

    /// @notice A transfer that fits the sender's balance. Must succeed and move exactly `amount`.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transfer(from, to, amount);
    }

    /// @notice Full-amount stress variant: the sender empties their account in one call.
    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _recipient(toSeed), token.balanceOf(from));
    }

    /// @notice Sets an allowance to any value at all, including zero and the maximum.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Approval(owner, spender, amount);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        ghostApprovals++;
        assertEq(token.allowance(owner, spender), amount, "allowance not what was approved");
    }

    /// @notice A delegated transfer within both the allowance and the owner's balance. Must succeed.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _recipient(toSeed);
        uint256 allowance = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        amount = bound(amount, 0, allowance < balance ? allowance : balance);
        _transferFrom(spender, owner, to, amount);
    }

    // ---------------------------------------------------------------- unclamped

    /// @notice A transfer of any amount. Above the balance it must fail with the ERC-6093 error and
    /// leave every balance untouched; otherwise it must succeed.
    function transferUnbounded(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        uint256 balance = token.balanceOf(from);
        if (amount <= balance) {
            _transfer(from, to, amount);
            return;
        }
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        assertFalse(ok, "transfer above balance succeeded");
        assertEq(
            ret,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount),
            "wrong error for transfer above balance"
        );
        assertEq(token.balanceOf(from), balance, "failed transfer changed the sender");
        assertEq(token.balanceOf(to), toBefore, "failed transfer changed the receiver");
        ghostRejectedTransfers++;
    }

    /// @notice A transfer to the zero address of any amount. Must always fail, even for zero.
    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 balance = token.balanceOf(from);
        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (address(0), amount)));
        assertFalse(ok, "transfer to the zero address succeeded");
        assertEq(
            ret,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)),
            "wrong error for transfer to the zero address"
        );
        assertEq(token.balanceOf(from), balance, "failed transfer changed the sender");
        ghostRejectedTransfers++;
    }

    /// @notice A delegated transfer of any amount. The allowance is checked before the balance, so
    /// the expected error depends on which bound is crossed first.
    function transferFromUnbounded(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _recipient(toSeed);
        uint256 allowance = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        bytes memory expected;
        if (allowance != type(uint256).max && amount > allowance) {
            expected =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount);
        } else if (amount > balance) {
            expected = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount);
        } else {
            _transferFrom(spender, owner, to, amount);
            return;
        }
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transferFrom, (owner, to, amount)));
        assertFalse(ok, "transferFrom beyond allowance or balance succeeded");
        assertEq(ret, expected, "wrong error for rejected transferFrom");
        assertEq(token.balanceOf(owner), balance, "failed transferFrom changed the owner");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom changed the receiver");
        assertEq(token.allowance(owner, spender), allowance, "failed transferFrom changed the allowance");
        ghostRejectedTransferFroms++;
    }

    /// @notice Tries one of the privileged entry points a token might expose, from a random actor
    /// (the deployer included). None exists, so every call must fail and nothing may change.
    function adminProbe(uint256 callerSeed, uint256 which, uint256 targetSeed) external {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        string memory signature = adminSignatures[which % adminSignatures.length];
        bytes memory data = abi.encodeWithSignature(signature, target, type(uint128).max);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, signature);
        ghostAdminProbes++;
    }

    /// @notice Sends ether to the token. There is no receive or fallback, so it must bounce.
    function sendEther(uint256 callerSeed, uint256 amount) external {
        address caller = _actor(callerSeed);
        amount = bound(amount, 1, 100 ether);
        vm.deal(caller, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0, "token holds ether");
        ghostEtherProbes++;
    }

    // ---------------------------------------------------------------- internals

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(from, to, amount);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        _recordMove(from, to, amount, fromBefore, toBefore);
        ghostTransfers++;
    }

    function _transferFrom(address spender, address owner, address to, uint256 amount) internal {
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 allowance = token.allowance(owner, spender);
        vm.prank(spender);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(owner, to, amount);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        _recordMove(owner, to, amount, ownerBefore, toBefore);
        if (allowance != type(uint256).max) {
            ghostAllowance[owner][spender] = allowance - amount;
        }
        assertEq(token.allowance(owner, spender), ghostAllowance[owner][spender], "allowance not spent exactly");
        ghostTransferFroms++;
    }

    function _recordMove(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore) internal {
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender did not lose exactly the amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver did not gain exactly the amount");
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _recipient(uint256 seed) internal view returns (address) {
        return recipients[bound(seed, 0, recipients.length - 1)];
    }
}

/// @notice Invariants of the fixed-supply token under random call sequences.
/// @dev The token holds every holder's balance, so the properties are the conservation ones: the
/// supply never changes, the balances of everyone who can hold tokens always sum to it, each balance
/// equals what the address was given plus what it received minus what it sent, and each allowance
/// is exactly what the owner last approved minus what was spent. Alongside them: no ether, no
/// balance at the zero address, and runtime code that never changes.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract IHOOKSTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    IHOOKSToken token;
    IHOOKSHandler handler;
    address deployer = makeAddr("deployer");
    bytes32 codeHashAtDeployment;

    function setUp() public {
        vm.prank(deployer);
        token = new IHOOKSToken();
        codeHashAtDeployment = address(token).codehash;
        handler = new IHOOKSHandler(token, deployer);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = IHOOKSHandler.transfer.selector;
        selectors[1] = IHOOKSHandler.transferAll.selector;
        selectors[2] = IHOOKSHandler.approve.selector;
        selectors[3] = IHOOKSHandler.transferFrom.selector;
        selectors[4] = IHOOKSHandler.transferUnbounded.selector;
        selectors[5] = IHOOKSHandler.transferToZero.selector;
        selectors[6] = IHOOKSHandler.transferFromUnbounded.selector;
        selectors[7] = IHOOKSHandler.adminProbe.selector;
        selectors[8] = IHOOKSHandler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The supply is minted once and nothing can mint or burn.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.INITIAL_SUPPLY(), SUPPLY, "constant changed");
    }

    /// @dev Everything that was minted is held by one of the addresses that can hold it. A fee, a
    /// burn-on-transfer, a reflection or a lost wei would break this.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.recipientCount(); ++i) {
            sum += token.balanceOf(handler.recipientAt(i));
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
    }

    /// @dev Each balance is exactly the flow the ghost accounting saw: nobody gains or loses
    /// anything a transfer did not say.
    function invariant_balanceEqualsNetFlow() public view {
        for (uint256 i; i < handler.recipientCount(); ++i) {
            address who = handler.recipientAt(i);
            uint256 expected = handler.initialBalance(who) + handler.ghostReceived(who) - handler.ghostSent(who);
            assertEq(token.balanceOf(who), expected, "balance differs from recorded flow");
        }
    }

    /// @dev Only the deployer started with anything.
    function invariant_onlyDeployerWasMintedTo() public view {
        for (uint256 i; i < handler.recipientCount(); ++i) {
            address who = handler.recipientAt(i);
            assertEq(handler.initialBalance(who), who == deployer ? SUPPLY : 0, "someone else was minted to");
        }
    }

    /// @dev Every allowance among the actors is what the owner last approved minus what was spent,
    /// with the maximum allowance never decremented. Nothing but approve and transferFrom moves it.
    function invariant_allowancesMatchGhosts() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actorAt(i);
                address spender = handler.actorAt(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
        }
    }

    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
    }

    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0, "token holds ether");
    }

    /// @dev No sequence of calls can change the code at the token's address.
    function invariant_runtimeCodeIsImmutable() public view {
        assertEq(address(token).codehash, codeHashAtDeployment, "runtime code changed");
        assertGt(address(token).code.length, 0, "token has no code");
    }

    // ---------------------------------------------------------------- harness grounding

    /// @dev Drives every handler path once with chosen seeds so a broken harness fails here rather
    /// than silently passing the invariants above by never reaching the token.
    function test_handlerReachesEveryPath() public {
        // seed 0 is the deployer, seed 1 holder1, seed 2 holder2; recipient seed 6 is the token.
        handler.transfer(0, 1, 1_000 ether);
        handler.transfer(0, 6, 1 ether);
        handler.transferAll(1, 2);
        handler.approve(0, 2, 10 ether);
        handler.approve(0, 1, type(uint256).max);
        handler.transferFrom(2, 0, 1, 10 ether);
        handler.transferFrom(1, 0, 2, 5 ether);
        handler.transferUnbounded(3, 2, 1);
        handler.transferUnbounded(2, 1, type(uint256).max);
        handler.transferToZero(0, 0);
        handler.transferFromUnbounded(2, 0, 1, 1);
        handler.transferFromUnbounded(1, 0, 2, SUPPLY);
        handler.transferFromUnbounded(1, 0, 2, 1);
        for (uint256 i; i < 22; ++i) {
            handler.adminProbe(i, i, i + 1);
        }
        handler.sendEther(3, 1 ether);

        assertEq(handler.ghostTransfers(), 3);
        assertEq(handler.ghostApprovals(), 2);
        assertEq(handler.ghostTransferFroms(), 3);
        assertEq(handler.ghostRejectedTransfers(), 3);
        assertEq(handler.ghostRejectedTransferFroms(), 2);
        assertEq(handler.ghostAdminProbes(), 22);
        assertEq(handler.ghostEtherProbes(), 1);

        invariant_totalSupplyNeverChanges();
        invariant_balancesSumToSupply();
        invariant_balanceEqualsNetFlow();
        invariant_allowancesMatchGhosts();
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.allowance(deployer, handler.actorAt(2)), 0);
        assertEq(token.allowance(deployer, handler.actorAt(1)), type(uint256).max);
    }
}
