// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AIArbiter} from "../src/AIArbiter.sol";
import {RentEscrow} from "../src/RentEscrow.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {MockUSDC} from "./helpers/MockUSDC.sol";
import {classifyArbiterCalls} from "./helpers/ArbiterCalls.sol";

/// @notice Drives AIArbiter + RentEscrow through random dispute histories: disputes opened at
///         random points, evidence, proposals (and replacements), appeals, executions attempted at
///         random times by random callers, human rulings, window changes, and unauthorized calls.
///         Every call into AIArbiter is state-diff recorded to check what AIArbiter itself calls.
contract ArbiterHandler is Test {
    RentEscrow public immutable escrow;
    AIArbiter public immutable arb;
    MockUSDC public immutable usdc;
    address public immutable human;
    address public immutable agent;
    address public immutable stranger;

    uint256 public currentTime;
    uint256[] public leases;
    mapping(uint256 => address) public tenantOf; // a fresh tenant/landlord pair per lease
    mapping(uint256 => address) public landlordOf;
    uint256 public totalMinted;

    // AI-1: what AIArbiter itself calls
    uint256 public ghostForbiddenCalls;
    uint256 public ghostResolves;
    // AI-3: rulings honoured
    mapping(uint256 => uint256) public ghostEscrowAtDispute;
    mapping(uint256 => uint256) public ghostLandlordAtDispute;
    mapping(uint256 => bool) public ghostAppealed;
    uint256 public ghostEarlyExecute; // an execute succeeded inside the window
    uint256 public ghostAppealIgnored; // an appealed lease was executed or re-proposed by the agent
    uint256 public ghostExecuteRefused; // an executable proposal failed to execute
    uint256 public ghostUnauthorizedSuccess; // a call by the wrong role went through

    mapping(bytes32 => uint256) public calls;

    modifier useTime() {
        vm.warp(currentTime);
        _;
    }

    constructor(RentEscrow escrow_, AIArbiter arb_, MockUSDC usdc_, address stranger_) {
        escrow = escrow_;
        arb = arb_;
        usdc = usdc_;
        human = arb_.human();
        agent = arb_.agent();
        stranger = stranger_;
        currentTime = block.timestamp;
    }

    function leaseCount() external view returns (uint256) {
        return leases.length;
    }

    // ------------------------------------------------------------------ helpers

    function _pick(uint256 seed) internal view returns (uint256 id) {
        if (leases.length == 0) return 0;
        id = leases[seed % leases.length];
        if (escrow.getLease(id).state != IRentEscrow.State.DISPUTED) return 0;
    }

    function _record() internal {
        vm.startStateDiffRecording();
    }

    function _check() internal {
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        (uint256 forbidden, uint256 resolves) = classifyArbiterCalls(accesses, address(arb), address(escrow));
        ghostForbiddenCalls += forbidden;
        ghostResolves += resolves;
    }

    function _open(uint256 id, uint64 deadline, AIArbiter.Status s) internal view returns (bool) {
        return s == AIArbiter.Status.PROPOSED && block.timestamp < deadline && id != 0;
    }

    // ------------------------------------------------------------------ actions

    /// A fresh lease, funded, some time passes (maybe rent is claimed), then either party disputes.
    function openDispute(uint256 deposit, uint256 rent, uint256 elapsed, bool claim, bool byTenant) external useTime {
        uint256 n = leases.length + 1;
        address landlord = address(uint160(0x1000 + 2 * n));
        address tenant = address(uint160(0x1001 + 2 * n));
        uint128 dep = uint128(bound(deposit, 0, 5_000e6));
        uint128 r = uint128(bound(rent, 0, 2_000e6));
        if (dep == 0 && r == 0) dep = 1;
        uint32 period = 60;
        uint16 periods = 5;

        vm.prank(landlord);
        uint256 id = escrow.createLease(tenant, dep, r, period, periods);
        uint256 total = uint256(dep) + uint256(r) * periods;
        usdc.mint(tenant, total);
        totalMinted += total;
        vm.startPrank(tenant);
        usdc.approve(address(escrow), total);
        escrow.fundLease(id);
        vm.stopPrank();

        currentTime += bound(elapsed, 0, uint256(period) * periods);
        vm.warp(currentTime);
        (uint16 due,) = escrow.claimable(id);
        if (claim && due != 0) escrow.claimRent(id);
        vm.prank(byTenant ? tenant : landlord);
        escrow.openDispute(id);

        leases.push(id);
        tenantOf[id] = tenant;
        landlordOf[id] = landlord;
        ghostEscrowAtDispute[id] = escrow.escrowBalance(id);
        ghostLandlordAtDispute[id] = usdc.balanceOf(landlord);
        calls["openDispute"]++;
    }

    function submitEvidence(uint256 seed, bool byTenant, uint256 len) external useTime {
        uint256 id = _pick(seed);
        if (id == 0) return;
        address party = byTenant ? tenantOf[id] : landlordOf[id];
        if (arb.evidenceCount(id, party) >= arb.MAX_STATEMENTS_PER_PARTY()) return;
        _record();
        vm.prank(party);
        arb.submitEvidence(id, string(new bytes(bound(len, 1, 1000))));
        _check();
        calls["submitEvidence"]++;
    }

    function propose(uint256 seed, uint16 bps, uint16 confidence) external useTime {
        uint256 id = _pick(seed);
        if (id == 0) return;
        AIArbiter.Ruling memory r = arb.getRuling(id);
        if (ghostAppealed[id]) {
            vm.prank(agent); // after an appeal the agent is out
            try arb.propose(id, 0, bytes32(0), 0, "") {
                ghostAppealIgnored++;
            } catch {}
            return;
        }
        if (r.status != AIArbiter.Status.NONE && !_open(id, r.deadline, r.status)) return;
        _record();
        vm.prank(agent);
        arb.propose(
            id, uint16(bound(bps, 0, 10_000)), keccak256(abi.encode(id, bps)), uint16(bound(confidence, 0, 10_000)), ""
        );
        _check();
        calls[r.status == AIArbiter.Status.NONE ? bytes32("propose") : bytes32("propose(replace)")]++;
    }

    function appeal(uint256 seed, bool byTenant) external useTime {
        uint256 id = _pick(seed);
        AIArbiter.Ruling memory r = arb.getRuling(id);
        if (!_open(id, r.deadline, r.status)) return;
        _record();
        vm.prank(byTenant ? tenantOf[id] : landlordOf[id]);
        arb.appeal(id);
        _check();
        ghostAppealed[id] = true;
        calls["appeal"]++;
    }

    /// Anyone tries to execute at a random moment; it must work exactly when the window is over.
    function execute(uint256 seed, uint256 callerSeed) external useTime {
        uint256 id = _pick(seed);
        if (id == 0) return;
        AIArbiter.Ruling memory r = arb.getRuling(id);
        address caller = [stranger, human, agent, tenantOf[id], landlordOf[id]][callerSeed % 5];
        bool executable = r.status == AIArbiter.Status.PROPOSED && block.timestamp >= r.deadline;
        _record();
        vm.prank(caller);
        try arb.execute(id) {
            if (!executable) ghostEarlyExecute++;
            if (ghostAppealed[id]) ghostAppealIgnored++;
            calls["execute"]++;
        } catch {
            if (executable) ghostExecuteRefused++;
            calls["execute(refused)"]++;
        }
        _check();
    }

    function resolveByHuman(uint256 seed, uint16 bps) external useTime {
        uint256 id = _pick(seed);
        if (id == 0) return;
        _record();
        vm.prank(human);
        arb.resolveByHuman(id, uint16(bound(bps, 0, 10_000)));
        _check();
        calls["resolveByHuman"]++;
    }

    function setChallengeWindow(uint32 window) external useTime {
        _record();
        vm.prank(human);
        arb.setChallengeWindow(uint32(bound(window, 60, 600)));
        _check();
        calls["setChallengeWindow"]++;
    }

    function warp(uint256 secs) external {
        currentTime += bound(secs, 0, 900);
        calls["warp"]++;
    }

    /// The wrong role tries a privileged call. None of these may ever succeed.
    function attack(uint256 seed, uint256 which, uint256 callerSeed, uint16 bps) external useTime {
        uint256 id = leases.length == 0 ? 1 : leases[seed % leases.length];
        address party = callerSeed % 2 == 0 ? tenantOf[id] : landlordOf[id];
        address[3] memory notHuman = [stranger, agent, party];
        address[3] memory notAgent = [stranger, human, party];
        address outsider = [stranger, agent, human][callerSeed % 3];
        bool ok;
        _record();
        uint256 w = which % 8;
        if (w == 0) {
            vm.prank(notAgent[callerSeed % 3]);
            try arb.propose(id, bps, bytes32(0), 0, "") {
                ok = true;
            } catch {}
        } else if (w == 1) {
            vm.prank(notHuman[callerSeed % 3]);
            try arb.resolveByHuman(id, bps) {
                ok = true;
            } catch {}
        } else if (w == 2) {
            vm.prank(notHuman[callerSeed % 3]);
            try arb.setAgent(stranger) {
                ok = true;
            } catch {}
        } else if (w == 3) {
            vm.prank(notHuman[callerSeed % 3]);
            try arb.setHuman(stranger) {
                ok = true;
            } catch {}
        } else if (w == 4) {
            vm.prank(notHuman[callerSeed % 3]);
            try arb.setChallengeWindow(60) {
                ok = true;
            } catch {}
        } else if (w == 5) {
            vm.prank(callerSeed % 2 == 0 ? human : stranger); // already bound: nobody can rebind
            try arb.bindEscrow(IRentEscrow(address(escrow))) {
                ok = true;
            } catch {}
        } else if (w == 6) {
            vm.prank(outsider);
            try arb.appeal(id) {
                ok = true;
            } catch {}
        } else {
            vm.prank(outsider);
            try arb.submitEvidence(id, "outsider") {
                ok = true;
            } catch {}
        }
        _check();
        if (ok) ghostUnauthorizedSuccess++;
        calls["attack"]++;
    }
}

/// @notice AIArbiter invariants. With RentEscrow's INV-1 / INV-4 they bound the damage of any
///         agent or human decision to a split of one disputed lease's own escrow between its parties.
contract AIArbiterInvariantTest is Test {
    MockUSDC internal usdc;
    RentEscrow internal escrow;
    AIArbiter internal arb;
    ArbiterHandler internal handler;

    address internal human = makeAddr("human");
    address internal agent = makeAddr("agent");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        arb = new AIArbiter(human, agent, 120);
        escrow = new RentEscrow(IERC20(address(usdc)), address(arb), address(0), address(0));
        vm.prank(human);
        arb.bindEscrow(escrow);
        handler = new ArbiterHandler(escrow, arb, usdc, stranger);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = ArbiterHandler.openDispute.selector;
        selectors[1] = ArbiterHandler.submitEvidence.selector;
        selectors[2] = ArbiterHandler.propose.selector;
        selectors[3] = ArbiterHandler.appeal.selector;
        selectors[4] = ArbiterHandler.execute.selector;
        selectors[5] = ArbiterHandler.resolveByHuman.selector;
        selectors[6] = ArbiterHandler.setChallengeWindow.selector;
        selectors[7] = ArbiterHandler.warp.selector;
        selectors[8] = ArbiterHandler.attack.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// AI-1: the only state-changing call AIArbiter ever makes is escrow.resolveDispute, and it
    /// makes exactly one per closed lease.
    function invariant_AI1_OnlyCallsEscrowResolveDispute() public {
        assertEq(handler.ghostForbiddenCalls(), 0, "AIArbiter made a forbidden call");
        uint256 closed;
        for (uint256 i; i < handler.leaseCount(); i++) {
            if (escrow.getLease(handler.leases(i)).state == IRentEscrow.State.CLOSED) closed++;
        }
        assertEq(handler.ghostResolves(), closed, "resolveDispute calls != closed leases");
    }

    /// AI-2: no funds ever reach anyone but a lease's own tenant and landlord: not the arbiter
    /// contract, the agent, the human or a stranger.
    function invariant_AI2_FundsOnlyReachLeaseParties() public {
        assertEq(usdc.balanceOf(address(arb)), 0, "arbiter contract holds tokens");
        assertEq(usdc.balanceOf(agent), 0, "agent holds tokens");
        assertEq(usdc.balanceOf(human), 0, "human holds tokens");
        assertEq(usdc.balanceOf(stranger), 0, "stranger holds tokens");
        uint256 sum = usdc.balanceOf(address(escrow));
        for (uint256 i; i < handler.leaseCount(); i++) {
            uint256 id = handler.leases(i);
            sum += usdc.balanceOf(handler.tenantOf(id)) + usdc.balanceOf(handler.landlordOf(id));
        }
        assertEq(sum, handler.totalMinted(), "tokens outside escrow + lease parties");
    }

    /// AI-3: a lease closes only through an executed (unappealed, window over) proposal or a human
    /// ruling, and pays exactly that ruling's split of the escrow left at the dispute. No privileged
    /// call by the wrong role ever succeeds, and an executable proposal can always be executed.
    function invariant_AI3_RulingsAreHonoured() public {
        assertEq(handler.ghostEarlyExecute(), 0, "executed inside the window / without an open proposal");
        assertEq(handler.ghostExecuteRefused(), 0, "an executable proposal could not be executed");
        assertEq(handler.ghostAppealIgnored(), 0, "an appealed proposal was executed or replaced");
        assertEq(handler.ghostUnauthorizedSuccess(), 0, "a call by the wrong role succeeded");
        for (uint256 i; i < handler.leaseCount(); i++) {
            uint256 id = handler.leases(i);
            AIArbiter.Ruling memory r = arb.getRuling(id);
            IRentEscrow.State s = escrow.getLease(id).state;
            if (s == IRentEscrow.State.DISPUTED) {
                assertTrue(
                    r.status == AIArbiter.Status.NONE || r.status == AIArbiter.Status.PROPOSED
                        || r.status == AIArbiter.Status.APPEALED,
                    "open lease with a final status"
                );
                continue;
            }
            assertEq(uint8(s), uint8(IRentEscrow.State.CLOSED));
            assertTrue(
                r.status == AIArbiter.Status.EXECUTED || r.status == AIArbiter.Status.HUMAN_RESOLVED,
                "closed without an executed proposal or a human ruling"
            );
            if (handler.ghostAppealed(id)) assertEq(uint8(r.status), uint8(AIArbiter.Status.HUMAN_RESOLVED));
            uint256 pot = handler.ghostEscrowAtDispute(id);
            uint256 toTenant = pot * r.tenantBps / 10_000;
            assertEq(usdc.balanceOf(handler.tenantOf(id)), toTenant, "tenant payout != ruling");
            assertEq(
                usdc.balanceOf(handler.landlordOf(id)),
                handler.ghostLandlordAtDispute(id) + pot - toTenant,
                "landlord payout != ruling"
            );
        }
    }
}
