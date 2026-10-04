import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/crypto"
import "@wrappers/PlanetCore.gen"
import "@contracts/oracle_state"
import "@contracts/limits"
import "@contracts/signed_price"

// Signed price updates: an off-chain relayer/adapter signs a PricePayload; PlanetCore
// verifies it on-chain (isSignatureValid) against the registered signer key(s). A second
// signer key enables dual-sign (2-of-2). See docs/oracle-ton.md, docs/security.md.

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
        oracleState: OracleState { oracle: deployer.address, signerKey: 0, signerKey2: 0, lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: 0, arbRebateBps: 0, riskFund: 0 }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, relayer);
}

// Wrap a 512-bit signature slice into a cell for the message.
fun sigCell(sig: slice): cell {
    return beginCell().storeSlice(sig).endCell();
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

get fun `test owner can set signer key`() {
    val (core, deployer, _) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, kp.publicKey as uint256, { value: ton("0.05") });
    expect(core.signerKey()).toEqual(kp.publicKey);
}

get fun `test non-owner cannot set signer key`() {
    val (core, _, relayer) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    val res = core.sendSetSigner(relayer.address, 0, kp.publicKey as uint256, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 101 });
}

get fun `test signed price update is verified and applied`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, kp.publicKey as uint256, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    val sig = crypto.sign(kp.privateKey, payload);
    core.sendSignedPriceUpdate(relayer.address, sigCell(sig), beginCell().endCell(), payload, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
    expect(core.lastOracleUpdate()).toEqual(1000);
}

get fun `test bad signature is rejected`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    val other = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, kp.publicKey as uint256, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    val sig = crypto.sign(other.privateKey, payload);
    val res = core.sendSignedPriceUpdate(relayer.address, sigCell(sig), beginCell().endCell(), payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 114 });
}

get fun `test signed update rejected when no signer set`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val kp = crypto.createMnemonic().toKeyPair();
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    val sig = crypto.sign(kp.privateKey, payload);
    val res = core.sendSignedPriceUpdate(relayer.address, sigCell(sig), beginCell().endCell(), payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 113 });
}

get fun `test dual-sign requires both signatures`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val kp1 = crypto.createMnemonic().toKeyPair();
    val kp2 = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, kp1.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner2(deployer.address, 0, kp2.publicKey as uint256, { value: ton("0.05") });
    expect(core.signerKey2()).toEqual(kp2.publicKey);
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    val s1 = crypto.sign(kp1.privateKey, payload);
    val s2 = crypto.sign(kp2.privateKey, payload);
    core.sendSignedPriceUpdate(relayer.address, sigCell(s1), sigCell(s2), payload, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1100000);
}

get fun `test dual-sign rejects a bad second signature`() {
    val (core, deployer, relayer) = deployCoreSigned();
    val kp1 = crypto.createMnemonic().toKeyPair();
    val kp2 = crypto.createMnemonic().toKeyPair();
    val wrong = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, kp1.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner2(deployer.address, 0, kp2.publicKey as uint256, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = samplePayload();
    val s1 = crypto.sign(kp1.privateKey, payload);
    val bad = crypto.sign(wrong.privateKey, payload);
    val res = core.sendSignedPriceUpdate(relayer.address, sigCell(s1), sigCell(bad), payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 117 });
}
