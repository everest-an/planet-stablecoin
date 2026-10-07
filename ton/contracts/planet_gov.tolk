// PlanetGov.tolk — PLTG governance: staking + pro-rata fee dividends + parameter voting.
//
// White paper §5/§7/§8.4: PLTG is a fixed-supply governance token; 25% of protocol fees are
// distributed to PLTG stakers, and stakers vote on protocol parameters (weights, fee rates,
// thresholds). Staking is done by transferring PLTG into the gov's OWN jetton wallet — the
// transfer notification credits the staker, and the staked balance weights their vote.
// Unstaking sends PLTG back via AskToTransfer. Rewards use a reward-per-share accumulator
// (same pattern the ether world uses), so distribution is O(1) per staker action.
//
// See docs/WHITEPAPER.md §0 (implementation map).

import "jetton/messages"

const RPS_SCALE = 1000000000000; // 1e12 reward-per-share fixed point

const ERR_NOT_OWNER = 401;
const ERR_PAUSED = 402;
const ERR_BAD_AMOUNT = 403;
const ERR_NOT_STAKER = 404;
const ERR_NOT_FUND_WALLET = 405;
const ERR_NO_REWARDS = 406;
const ERR_BAD_PROPOSAL = 407;
const ERR_ALREADY_VOTED = 408;
const ERR_VOTE_CLOSED = 409;
const ERR_NO_PROPOSAL = 410;
const ERR_VOTE_LOCKED = 411; // stake still locked by an unclosed proposal you voted on (GV-1)

// ---------------- Storage ----------------

struct StakerInfo {
    amount: int64      // staked PLTG (6 decimals)
    rewardDebt: int64  // amount * accRewardPerShare / RPS_SCALE at last accrual
}

struct Proposal {
    kind: int64        // parameter class (opaque here; executed out-of-band via the timelock)
    value: int64       // proposed value
    endTs: int64       // voting deadline
    forVotes: int64    // Σ staked PLTG voting yes
    againstVotes: int64
    executed: bool
}

struct GovWalletRef {
    addr: address
}

struct GovStorage {
    owner: address
    pltMinter: address
    govWallet: cell                 // the gov's own PLTG jetton wallet (verified on stake receipt)
    totalStaked: int64
    accRewardPerShare: int64        // 1e12 fixed point
    accRewards: int64               // cumulative reward units distributed
    paused: bool
    proposals: map<int64, Proposal>
    stakes: map<address, StakerInfo>
    lastVote: map<address, int64>   // address -> last proposal id voted on (one vote per proposal)
}

fun GovStorage.load() {
    return GovStorage.fromCell(contract.getData())
}

fun GovStorage.save(self) {
    contract.setData(self.toCell())
}

fun loadGovWallet(st: GovStorage): address {
    return GovWalletRef.fromCell(st.govWallet).addr;
}

// ---------------- Messages ----------------

struct (0x40000001) SetPaused {
    queryId: int64
    paused: bool
}

struct (0x40000002) SetPltMinter {
    queryId: int64
    minter: address
}

struct (0x40000003) SetGovWallet {
    queryId: int64
    wallet: address
}

struct (0x40000004) Unstake {
    queryId: int64
    amount: int64
}

struct (0x40000005) NotifyRewards {
    queryId: int64
    amount: int64
}

struct (0x40000006) Claim {
    queryId: int64
}

struct (0x40000007) Propose {
    queryId: int64
    id: int64
    kind: int64
    value: int64
    endTs: int64
}

struct (0x40000008) Vote {
    queryId: int64
    id: int64
    support: bool
}

struct (0x40000009) SetOwner {
    queryId: int64
    newOwner: address
}

type GovMessage = SetPaused | SetPltMinter | SetGovWallet | Unstake | NotifyRewards | Claim |
    Propose | Vote | SetOwner | TransferNotificationForRecipient

contract PlanetGov {
    storage: GovStorage
    incomingMessages: GovMessage
}

// ---------------- Handling ----------------

fun onInternalMessage(in: InMessage) {
    val msg = lazy GovMessage.fromSlice(in.body);
    match (msg) {
        SetPaused => { handleSetPaused(in.senderAddress, msg); }
        SetPltMinter => { handleSetPltMinter(in.senderAddress, msg); }
        SetGovWallet => { handleSetGovWallet(in.senderAddress, msg); }
        Unstake => { handleUnstake(in.senderAddress, msg); }
        NotifyRewards => { handleNotifyRewards(in.senderAddress, msg); }
        Claim => { handleClaim(in.senderAddress, msg); }
        Propose => { handlePropose(in.senderAddress, msg); }
        Vote => { handleVote(in.senderAddress, msg); }
        SetOwner => { handleSetOwner(in.senderAddress, msg); }
        TransferNotificationForRecipient => { handleStake(in.senderAddress, msg); }
        else => { assert (in.body.isEmpty()) throw 0xFFFF; }
    }
}

// Ignore bounced bodies (never parse them as commands).
fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
}

// TEP-74: the gov's own PLTG wallet reports received tokens -> credit the ORIGINAL sender.
fun handleStake(sender: address, msg: TransferNotificationForRecipient) {
    var storage = lazy GovStorage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    val gw = loadGovWallet(storage);
    assert (sender == gw) throw ERR_NOT_FUND_WALLET;
    assert (msg.jettonAmount as int > 0) throw ERR_BAD_AMOUNT;
    val staker = msg.transferInitiator!; // null (a mint) is rejected by the unwrap

    var amount: int64 = 0;
    val lk = storage.stakes.get(staker);
    if (lk.isFound) {
        amount = lk.loadValue().amount;
    }
    val add = msg.jettonAmount as int64;
    val newAmount = amount + add;
    storage.totalStaked += add;
    val debt = (newAmount as int) * (storage.accRewardPerShare as int) / RPS_SCALE;
    storage.stakes.set(staker, StakerInfo { amount: newAmount, rewardDebt: debt as int64 });
    storage.save();
}

// Send staked PLTG back to the staker from the gov's own jetton wallet.
fun handleUnstake(sender: address, msg: Unstake) {
    var storage = lazy GovStorage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    assert (msg.amount > 0) throw ERR_BAD_AMOUNT;
    // GV-1: a vote must not be free. Voting power is read from the CURRENT stake, so without a
    // lock a staker could vote and immediately withdraw, keeping the vote and losing nothing.
    // The stake stays locked until the proposal they last voted on has closed.
    val lv = storage.lastVote.get(sender);
    if (lv.isFound) {
        val pl = storage.proposals.get(lv.loadValue());
        if (pl.isFound) {
            assert ((blockchain.now() as int64) > pl.loadValue().endTs) throw ERR_VOTE_LOCKED;
        }
    }
    val lk = storage.stakes.get(sender);
    assert (lk.isFound) throw ERR_NOT_STAKER;
    val s = lk.loadValue();
    assert (s.amount >= msg.amount) throw ERR_BAD_AMOUNT;

    val newAmount = s.amount - msg.amount;
    storage.totalStaked -= msg.amount;
    val debt = (newAmount as int) * (storage.accRewardPerShare as int) / RPS_SCALE;
    storage.stakes.set(sender, StakerInfo { amount: newAmount, rewardDebt: debt as int64 });
    val gw = loadGovWallet(storage);
    storage.save();

    val transfer = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        value: 0,
        dest: gw,
        body: AskToTransfer {
            queryId: msg.queryId as uint64,
            jettonAmount: msg.amount as coins,
            transferRecipient: sender,
            sendExcessesTo: null,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: beginCell().endCell().beginParse(),
        },
    });
    transfer.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// Owner funds the staker dividend pool (the 25% fee bucket from PlanetCore's feesToStaking).
fun handleNotifyRewards(sender: address, msg: NotifyRewards) {
    var storage = lazy GovStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    assert (msg.amount > 0) throw ERR_BAD_AMOUNT;
    assert (storage.totalStaked > 0) throw ERR_NOT_STAKER;
    storage.accRewardPerShare += ((msg.amount as int) * RPS_SCALE / (storage.totalStaked as int)) as int64;
    storage.accRewards += msg.amount;
    storage.save();
}

// Staker withdraws the dividends accrued since their last accrual.
fun handleClaim(sender: address, msg: Claim) {
    var storage = lazy GovStorage.load();
    val lk = storage.stakes.get(sender);
    assert (lk.isFound) throw ERR_NOT_STAKER;
    val s = lk.loadValue();
    val accrued = (s.amount as int) * (storage.accRewardPerShare as int) / RPS_SCALE;
    val pending = accrued - (s.rewardDebt as int);
    assert (pending > 0) throw ERR_NO_REWARDS;
    storage.stakes.set(sender, StakerInfo { amount: s.amount, rewardDebt: accrued as int64 });
    storage.save();

    val pay = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: sender,
        body: beginCell().storeUint(0x4000000A, 32).storeInt(pending as int64, 64).endCell(),
    });
    pay.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

// A staker opens a parameter proposal. Execution is out-of-band (via the timelock), so the
// contract only records intent + the vote tally.
fun handlePropose(sender: address, msg: Propose) {
    var storage = lazy GovStorage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    val lk = storage.stakes.get(sender);
    assert (lk.isFound && lk.loadValue().amount > 0) throw ERR_NOT_STAKER;
    assert (msg.id > 0) throw ERR_BAD_PROPOSAL;
    assert (msg.endTs > blockchain.now() as int64) throw ERR_BAD_PROPOSAL;
    storage.proposals.set(msg.id, Proposal {
        kind: msg.kind,
        value: msg.value,
        endTs: msg.endTs,
        forVotes: 0,
        againstVotes: 0,
        executed: false,
    });
    storage.save();
}

// Vote weighted by the staker's CURRENT staked balance. A staker may vote at most once per
// proposal id (tracked by `lastVote`).
fun handleVote(sender: address, msg: Vote) {
    var storage = lazy GovStorage.load();
    assert (!storage.paused) throw ERR_PAUSED;
    val sk = storage.stakes.get(sender);
    assert (sk.isFound) throw ERR_NOT_STAKER;
    val amount = sk.loadValue().amount;
    assert (amount > 0) throw ERR_NOT_STAKER;

    val lv = storage.lastVote.get(sender);
    assert (!(lv.isFound && lv.loadValue() == msg.id)) throw ERR_ALREADY_VOTED;

    val pl = storage.proposals.get(msg.id);
    assert (pl.isFound) throw ERR_NO_PROPOSAL;
    val p = pl.loadValue();
    assert (blockchain.now() as int64 <= p.endTs) throw ERR_VOTE_CLOSED;

    var fv = p.forVotes;
    var av = p.againstVotes;
    if (msg.support) {
        fv += amount;
    } else {
        av += amount;
    }
    storage.proposals.set(msg.id, Proposal {
        kind: p.kind,
        value: p.value,
        endTs: p.endTs,
        forVotes: fv,
        againstVotes: av,
        executed: p.executed,
    });
    storage.lastVote.set(sender, msg.id);
    storage.save();
}

// ---------------- Owner setters ----------------

fun handleSetPaused(sender: address, msg: SetPaused) {
    var storage = lazy GovStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.paused = msg.paused;
    storage.save();
}

fun handleSetPltMinter(sender: address, msg: SetPltMinter) {
    var storage = lazy GovStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.pltMinter = msg.minter;
    storage.save();
}

fun handleSetGovWallet(sender: address, msg: SetGovWallet) {
    var storage = lazy GovStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    storage.govWallet = GovWalletRef { addr: msg.wallet }.toCell();
    storage.save();
}

fun handleSetOwner(sender: address, msg: SetOwner) {
    var storage = lazy GovStorage.load();
    assert (sender == storage.owner) throw ERR_NOT_OWNER;
    val (wc, h) = msg.newOwner.getWorkchainAndHash();
    assert (!(wc == 0 && h == 0)) throw ERR_NOT_OWNER;
    storage.owner = msg.newOwner;
    storage.save();
}

// ---------------- Getters ----------------

get fun owner(): address {
    val storage = lazy GovStorage.load();
    return storage.owner;
}

get fun pltMinter(): address {
    val storage = lazy GovStorage.load();
    return storage.pltMinter;
}

get fun govWallet(): address {
    val storage = lazy GovStorage.load();
    return loadGovWallet(storage);
}

get fun totalStaked(): int64 {
    val storage = lazy GovStorage.load();
    return storage.totalStaked;
}

get fun accRewardPerShare(): int64 {
    val storage = lazy GovStorage.load();
    return storage.accRewardPerShare;
}

get fun accRewards(): int64 {
    val storage = lazy GovStorage.load();
    return storage.accRewards;
}

get fun isPaused(): bool {
    val storage = lazy GovStorage.load();
    return storage.paused;
}

// Throws if the address has never staked.
get fun stakeOf(who: address): StakerInfo {
    val storage = lazy GovStorage.load();
    return storage.stakes.mustGet(who);
}

get fun pendingOf(who: address): int64 {
    val storage = lazy GovStorage.load();
    val s = storage.stakes.mustGet(who);
    val accrued = (s.amount as int) * (storage.accRewardPerShare as int) / RPS_SCALE;
    return (accrued - (s.rewardDebt as int)) as int64;
}

get fun proposalAt(id: int64): Proposal {
    val storage = lazy GovStorage.load();
    return storage.proposals.mustGet(id);
}

get fun lastVoteOf(who: address): int64 {
    val storage = lazy GovStorage.load();
    val lk = storage.lastVote.get(who);
    if (!lk.isFound) {
        return 0;
    }
    return lk.loadValue();
}

// Canonical wire encoding of the stake notification (TEP-74 0x7362d09c), produced by Tolk's
// own serializer so wallets/integrators (and tests) send EXACTLY what `handleStake` parses:
// a PLTG transfer to the gov's jetton wallet with queryId | amount | staker | empty payload.
get fun stakeMessage(queryId: int64, amount: int64, staker: address): cell {
    return TransferNotificationForRecipient {
        queryId: queryId as uint64,
        jettonAmount: amount as coins,
        transferInitiator: staker,
        forwardPayload: beginCell().endCell().beginParse(),
    }.toCell();
}
