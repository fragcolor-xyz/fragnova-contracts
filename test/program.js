var nft = artifacts.require("HastenScript");
var modNft = artifacts.require("HastenMod");

contract("HastenScript", accounts => {
  const scriptHash = web3.utils.toHex("82244645650067078051647883681477212594888008908680932184588990116864531889524");

  it("should upload a script", async () => {
    const contract = await nft.deployed();
    scriptContract = contract;
    assert.equal(await contract.totalSupply.call(), 0);
    const emptyCode = new Uint8Array(1024);
    const tx = await contract.upload("", emptyCode, { from: accounts[0] });
    assert.equal(tx.logs[0].args.tokenId.toString(), "82244645650067078051647883681477212594888008908680932184588990116864531889524");
    assert.equal(tx.receipt.gasUsed, 228502);
    assert.equal(await contract.totalSupply.call(), 1);
    assert.equal(await contract.ownerOf.call(tx.logs[0].args.tokenId), accounts[0]);
    const script = await contract.script.call(tx.logs[0].args.tokenId);
    const codeHex = web3.utils.bytesToHex(emptyCode);
    assert.equal(script.scriptBytes, codeHex);
  });

  it("should not upload a script", async () => {
    try {
      const contract = await nft.deployed();
      assert.equal(await contract.totalSupply.call(), 1);
      const emptyCode = new Uint8Array(1024);
      await contract.uploadWithEnvironment("", emptyCode, emptyCode, { from: accounts[0] });
    } catch (e) {
      assert(e.toString() == "Error: Returned error: VM Exception while processing transaction: revert ERC721: token already minted -- Reason given: ERC721: token already minted.");
      return;
    }
    assert(false, "expected exception not thrown");
  });

  it("should upload a script with environment", async () => {
    const contract = await nft.deployed();
    assert.equal(await contract.totalSupply.call(), 1);
    const emptyCode = new Uint8Array(1024);
    emptyCode[0] = 1; // make a small change in order to succeed
    const tx = await contract.uploadWithEnvironment("", emptyCode, emptyCode, { from: accounts[0] });
    assert.equal(tx.logs[0].args.tokenId.toString(), "22245867104185935282213184455643255424572845908357372064232261761039889590899");
    assert.equal(tx.receipt.gasUsed, 290976);
    assert.equal(await contract.totalSupply.call(), 2);
    assert.equal(await contract.ownerOf.call(tx.logs[0].args.tokenId), accounts[0]);
    const script = await contract.script.call(tx.logs[0].args.tokenId);
    const codeHex = web3.utils.bytesToHex(emptyCode);
    assert.equal(script.scriptBytes, codeHex);
    assert.equal(script.environment, codeHex);
  });

  it("should not update a script's environment", async () => {
    try {
      const contract = await nft.deployed();
      const emptyCode = new Uint8Array(30);
      await contract.update(scriptHash, emptyCode, { from: accounts[1] });
    } catch (e) {
      assert(e.reason == "Only the owner of the script can update its environment");
      return;
    }
    assert(false, "expected exception not thrown");
  });

  it("should update a script's environment", async () => {
    const contract = await nft.deployed();
    const emptyCode = new Uint8Array(30);
    await contract.update(scriptHash, emptyCode, { from: accounts[0] });
    const script = await contract.script.call(scriptHash);
    const codeHex = web3.utils.bytesToHex(emptyCode);
    assert.equal(script.environment, codeHex);
  });

  it("should upload a mod", async () => {
    const scontract = await nft.deployed();
    const contract = await modNft.new(scontract.address);
    const empty = new Uint8Array(1024);
    const tx = await contract.upload("", scriptHash, empty, { from: accounts[0] });
    assert.equal(tx.logs[0].args.tokenId.toString(), 1);
    assert.equal(tx.receipt.gasUsed, 276287);
    assert.equal(await contract.totalSupply.call(), 1);
    assert.equal(await contract.ownerOf.call(tx.logs[0].args.tokenId), accounts[0]);
    const script = await contract.script.call(tx.logs[0].args.tokenId);
    const codeHex = web3.utils.bytesToHex(empty);
    assert.equal(script.scriptBytes, codeHex);
  });

  it("should not upload a mod", async () => {
    try {
      const scontract = await nft.deployed();
      const contract = await modNft.new(scontract.address);
      const empty = new Uint8Array(1024);
      const tx = await contract.upload("", scriptHash, empty, { from: accounts[1] });
      assert.equal(tx.logs[0].args.tokenId.toString(), 1);
      assert.equal(tx.receipt.gasUsed, 276287);
      assert.equal(await contract.totalSupply.call(), 1);
      assert.equal(await contract.ownerOf.call(tx.logs[0].args.tokenId), accounts[1]);
      const script = await contract.script.call(tx.logs[0].args.tokenId);
      const codeHex = web3.utils.bytesToHex(empty);
      assert.equal(script.scriptBytes, codeHex);
    } catch (e) {
      assert(e.reason == "Only the owner of the script can upload mods");
      return;
    }
    assert(false, "expected exception not thrown");
  });
});
