import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/crypto"
import "@wrappers/PlanetCore.gen"
import "@contracts/oracle_state"
import "@contracts/limits"
import "@contracts/signed_price"

// Signed price updates with a THRESHOLD signer set (multi-source): register N signer
// keys, set threshold M, and an update needs M distinct valid signatures. See
// docs/oracle-ton.md, docs/security.md.

fun deployCoreSigned(): (PlanetCore, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val relayer = testing.treasury("relayer");
    val core = PlanetCore.fromStorage({
        owner: deployer.address,
        jettonMinter: deployer.address,
        totalReserve: 0,
        totalSupply: 0,
        currentPpi: 1000000,
        feesToBurn: 0,
        feesToReserve: 0,
        feesToStaking: 0,
        paused: false,
        assets: [],
        cams: [],
        assetCount: 0,
        baseLocked: false,
        oracleState: OracleState { oracle: deployer.address, signerCount: 0, threshold: 0, signers: [], lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0, bond: address("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c"), bondOpen: false, bondPaid: 0 }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, relayer);
}

fun sigCell(sig: slice): cell {
    return beginCell().storeSlice(sig).endCell();
}

// `sigs` layout for SignedPriceUpdateN: uint8 count + count refs (one sig each).
fun sigsCell2(a: cell, b: cell): cell {
    return beginCell().storeUint(2, 8).storeRef(a).storeRef(b).endCell();
}

fun sigsCell3(a: cell, b: cell, c: cell): cell {
    return beginCell().storeUint(3, 8).storeRef(a).storeRef(b).storeRef(c).endCell();
}

// Domain-separated signed cell: matches PlanetCore.priceHash (tag + core address + payload).
fun domCell(payload: cell, core: address): cell {
    return beginCell().storeUint(0x504C4E54, 32).storeAddress(core).storeRef(payload).endCell();
}

fun samplePayload(): cell {
    return PricePayload {
        queryId: 0,
        index: 0,
        price: 1100000,
        volatility: 0,
        liquidity: 1000000,
        riskState: 0,
        timestamp: 1000,
    }.toCell();
}

get fun `test owner can register signers and set threshold`() {
    val (core, deployer, _) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    val b = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 1, b.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 2, { value: ton("0.05") });
    expect(core.signerCount()).toEqual(2);
    expect(core.threshold()).toEqual(2);
    expect(core.signerAt(0)).toEqual(a.publicKey);
}

get fun `test non-owner cannot register signer`() {
    val (core, _, relayer) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    val res = core.sendSetSigner(relayer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 101 });
}

get fun `test single-signer update is applied`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 1, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    val s1 = crypto.sign(a.privateKey, domCell(payload, core.address));
    core.sendSignedPriceUpdate(relayer.address, sigCell(s1), beginCell().endCell(), payload, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
}

get fun `test update rejected without signers`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    val s1 = crypto.sign(a.privateKey, domCell(payload, core.address));
    val res = core.sendSignedPriceUpdate(relayer.address, sigCell(s1), beginCell().endCell(), payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 113 });
}

get fun `test bad signature is rejected`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    val other = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 1, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    val bad = crypto.sign(other.privateKey, domCell(payload, core.address));
    val res = core.sendSignedPriceUpdate(relayer.address, sigCell(bad), beginCell().endCell(), payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 114 });
}

get fun `test 2-of-3 requires two distinct signers`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    val b = crypto.createMnemonic().toKeyPair();
    val c = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 1, b.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 2, c.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 2, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    // two distinct valid signers (a and c) -> OK
    val sa = crypto.sign(a.privateKey, domCell(payload, core.address));
    val sc = crypto.sign(c.privateKey, domCell(payload, core.address));
    core.sendSignedPriceUpdate(relayer.address, sigCell(sa), sigCell(sc), payload, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
}

get fun `test 2-of-3 rejects when both signatures are from the same signer`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    val b = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 1, b.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 2, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    // both signatures from `a` -> only one distinct signer -> rejected
    val sa1 = crypto.sign(a.privateKey, domCell(payload, core.address));
    val sa2 = crypto.sign(a.privateKey, domCell(payload, core.address));
    val res = core.sendSignedPriceUpdate(relayer.address, sigCell(sa1), sigCell(sa2), payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 117 });
}

get fun `test N-signature update: 3-of-3 distinct signers applied`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    val b = crypto.createMnemonic().toKeyPair();
    val c = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 1, b.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 2, c.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 3, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    val sigs = sigsCell3(sigCell(crypto.sign(a.privateKey, domCell(payload, core.address))), sigCell(crypto.sign(b.privateKey, domCell(payload, core.address))), sigCell(crypto.sign(c.privateKey, domCell(payload, core.address))));
    core.sendSignedPriceUpdateN(relayer.address, sigs, payload, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
}

get fun `test N-signature update: too few signatures rejected`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    val b = crypto.createMnemonic().toKeyPair();
    val c = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 1, b.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 2, c.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 3, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    // only 2 signatures for a 3-of-3 threshold -> matched(2) < 3 -> rejected
    val sigs = sigsCell2(sigCell(crypto.sign(a.privateKey, domCell(payload, core.address))), sigCell(crypto.sign(b.privateKey, domCell(payload, core.address))));
    val res = core.sendSignedPriceUpdateN(relayer.address, sigs, payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 117 });
}

get fun `test N-signature update: duplicate signer does not count twice`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    val b = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 1, b.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 2, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    // two copies of `a`'s signature -> only one distinct signer -> rejected
    val sigs = sigsCell2(sigCell(crypto.sign(a.privateKey, domCell(payload, core.address))), sigCell(crypto.sign(a.privateKey, domCell(payload, core.address))));
    val res = core.sendSignedPriceUpdateN(relayer.address, sigs, payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 117 });
}

// Regression (OR1): a non-contiguous signer set must not brick price updates.
get fun `test signer slot gap does not brick updates`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val b = crypto.createMnemonic().toKeyPair();
    // register ONLY slot 1 (slot 0 left empty) -> signerCount becomes 2
    core.sendSetSigner(deployer.address, 0, 1, b.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 1, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    core.sendSignedPriceUpdate(relayer.address, sigCell(crypto.sign(b.privateKey, domCell(payload, core.address))), beginCell().endCell(), payload, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
}

// Regression (AC2): ownership cannot be set to the zero address.
get fun `test SetOwner rejects the zero address`() {
    val (core, deployer, _) = deployCoreSigned();
    val res = core.sendSetOwner(deployer.address, 0, address("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c"), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 120 });
}

// Regression (AC3): threshold must be satisfiable (<= signerCount).
get fun `test threshold cannot exceed signer count`() {
    val (core, deployer, _) = deployCoreSigned();
    val a = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    val res = core.sendSetThreshold(deployer.address, 0, 3, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 119 });
}
