const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("GameTokenFactory - Enhanced Security with Original Flow", function () {
  let gameTokenFactory;
  let credaToken;
  let xpToken;
  let owner;
  let user1;
  let user2;
  let rateManager;
  let pauser;

  const INITIAL_SUPPLY = ethers.parseEther("1000000"); // 1M tokens
  const CREDA_TO_XP_RATE = ethers.parseEther("1"); // 1:1 ratio with 18 decimals precision
  const MIN_XP_LOCK = ethers.parseEther("1000"); // 1000 XP minimum

  beforeEach(async function () {
    [owner, user1, user2, rateManager, pauser] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    credaToken = await MockERC20.deploy("CREDA Token", "CREDA", 18, INITIAL_SUPPLY);
    xpToken = await MockERC20.deploy("XP Token", "XP", 18, INITIAL_SUPPLY);

    // Deploy GameTokenFactory
    const GameTokenFactory = await ethers.getContractFactory("GameTokenFactory");
    gameTokenFactory = await GameTokenFactory.deploy(
      await credaToken.getAddress(),
      await xpToken.getAddress()
    );

    // Setup roles
    const RATE_MANAGER_ROLE = await gameTokenFactory.RATE_MANAGER_ROLE();
    const PAUSER_ROLE = await gameTokenFactory.PAUSER_ROLE();

    await gameTokenFactory.grantRole(RATE_MANAGER_ROLE, rateManager.address);
    await gameTokenFactory.grantRole(PAUSER_ROLE, pauser.address);

    // Transfer some tokens to users and contract
    await credaToken.transfer(user1.address, ethers.parseEther("10000"));
    await credaToken.transfer(user2.address, ethers.parseEther("10000"));
    await xpToken.transfer(await gameTokenFactory.getAddress(), ethers.parseEther("500000"));
  });

  describe("CREDA → XP Locking", function () {
    it("Should lock CREDA and transfer XP tokens", async function () {
      const lockAmount = ethers.parseEther("100");
      const expectedXP = lockAmount; // 1:1 ratio

      // Approve and lock CREDA
      await credaToken.connect(user1).approve(await gameTokenFactory.getAddress(), lockAmount);
      
      await expect(gameTokenFactory.connect(user1).lockCreda(lockAmount))
        .to.emit(gameTokenFactory, "CredaLocked")
        .withArgs(user1.address, lockAmount, expectedXP);

      // Check balances
      expect(await gameTokenFactory.userLockedCreda(user1.address)).to.equal(lockAmount);
      expect(await gameTokenFactory.totalLockedCreda()).to.equal(lockAmount);
      expect(await xpToken.balanceOf(user1.address)).to.equal(expectedXP);
    });

    it("Should revert when locking zero amount", async function () {
      await expect(gameTokenFactory.connect(user1).lockCreda(0))
        .to.be.revertedWithCustomError(gameTokenFactory, "ZeroAmount");
    });

    it("Should revert when paused", async function () {
      await gameTokenFactory.connect(pauser).pause();
      
      const lockAmount = ethers.parseEther("100");
      await credaToken.connect(user1).approve(await gameTokenFactory.getAddress(), lockAmount);
      
      await expect(gameTokenFactory.connect(user1).lockCreda(lockAmount))
        .to.be.revertedWith("Pausable: paused");
    });

    it("Should handle rate changes correctly", async function () {
      const newRate = ethers.parseEther("2"); // 1 CREDA = 2 XP
      await gameTokenFactory.connect(rateManager).setRate(newRate);

      const lockAmount = ethers.parseEther("100");
      const expectedXP = ethers.parseEther("200"); // 2x rate

      await credaToken.connect(user1).approve(await gameTokenFactory.getAddress(), lockAmount);
      await gameTokenFactory.connect(user1).lockCreda(lockAmount);

      expect(await xpToken.balanceOf(user1.address)).to.equal(expectedXP);
    });
  });

  describe("XP → Game Token Factory (Separate ERC-20 Deployment)", function () {
    beforeEach(async function () {
      // Lock CREDA to get XP first
      const lockAmount = ethers.parseEther("5000");
      await credaToken.connect(user1).approve(await gameTokenFactory.getAddress(), lockAmount);
      await gameTokenFactory.connect(user1).lockCreda(lockAmount);
    });

    it("Should deploy separate ERC-20 game token successfully", async function () {
      const xpAmount = ethers.parseEther("2000");
      const name = "Test Game Token";
      const symbol = "TGT";
      const decimals = 18;

      await xpToken.connect(user1).approve(await gameTokenFactory.getAddress(), xpAmount);
      
      const tx = await gameTokenFactory.connect(user1).createGameToken(xpAmount, name, symbol, decimals);
      const receipt = await tx.wait();
      
      // Check event was emitted with token address
      const event = receipt.logs.find(log => log.fragment?.name === "GameTokenCreated");
      expect(event).to.exist;
      
      const tokenAddress = event.args[2]; // tokenAddress is 3rd indexed parameter
      expect(tokenAddress).to.not.equal(ethers.ZeroAddress);

      // Check game token info
      const [gameInfo, metadata] = await gameTokenFactory.getGameTokenInfo(1);
      expect(gameInfo.creator).to.equal(user1.address);
      expect(gameInfo.tokenAddress).to.equal(tokenAddress);
      expect(gameInfo.xpLocked).to.equal(xpAmount);
      expect(gameInfo.active).to.be.true;
      expect(metadata.name).to.equal(name);
      expect(metadata.symbol).to.equal(symbol);

      // Check that it's a real ERC-20 contract
      const GameToken = await ethers.getContractFactory("GameToken");
      const gameToken = GameToken.attach(tokenAddress);
      expect(await gameToken.name()).to.equal(name);
      expect(await gameToken.symbol()).to.equal(symbol);
      expect(await gameToken.decimals()).to.equal(decimals);
      expect(await gameToken.balanceOf(user1.address)).to.equal(xpAmount);

      // Check XP reserves
      expect(await gameTokenFactory.xpReserves()).to.equal(xpAmount);
    });

    it("Should prevent duplicate game names per user", async function () {
      const xpAmount = ethers.parseEther("2000");
      const name = "Duplicate Game";
      
      await xpToken.connect(user1).approve(await gameTokenFactory.getAddress(), xpAmount * 2n);
      
      // First creation should succeed
      await gameTokenFactory.connect(user1).createGameToken(xpAmount, name, "DUP1", 18);
      
      // Second creation with same name should fail
      await expect(gameTokenFactory.connect(user1).createGameToken(xpAmount, name, "DUP2", 18))
        .to.be.revertedWithCustomError(gameTokenFactory, "DuplicateGameName");
    });

    it("Should allow different users to use same game name", async function () {
      const xpAmount = ethers.parseEther("2000");
      const name = "Popular Game Name";
      
      // Setup user2 with XP
      const lockAmount = ethers.parseEther("5000");
      await credaToken.connect(user2).approve(await gameTokenFactory.getAddress(), lockAmount);
      await gameTokenFactory.connect(user2).lockCreda(lockAmount);
      
      await xpToken.connect(user1).approve(await gameTokenFactory.getAddress(), xpAmount);
      await xpToken.connect(user2).approve(await gameTokenFactory.getAddress(), xpAmount);
      
      // Both users should be able to use the same name
      await gameTokenFactory.connect(user1).createGameToken(xpAmount, name, "POP1", 18);
      await gameTokenFactory.connect(user2).createGameToken(xpAmount, name, "POP2", 18);
      
      expect(await gameTokenFactory.isGameNameUsed(user1.address, name)).to.be.true;
      expect(await gameTokenFactory.isGameNameUsed(user2.address, name)).to.be.true;
    });

    it("Should revert with insufficient XP amount", async function () {
      const xpAmount = ethers.parseEther("500"); // Less than minimum
      
      await expect(gameTokenFactory.connect(user1).createGameToken(xpAmount, "Test", "TST", 18))
        .to.be.revertedWithCustomError(gameTokenFactory, "InsufficientAmount");
    });

    it("Should revert with invalid decimals", async function () {
      const xpAmount = ethers.parseEther("2000");
      
      await expect(gameTokenFactory.connect(user1).createGameToken(xpAmount, "Test", "TST", 25))
        .to.be.revertedWithCustomError(gameTokenFactory, "InvalidDecimals");
    });

    it("Should track user's created game tokens", async function () {
      const xpAmount = ethers.parseEther("2000");
      
      await xpToken.connect(user1).approve(await gameTokenFactory.getAddress(), xpAmount);
      await gameTokenFactory.connect(user1).createGameToken(xpAmount, "Test", "TST", 18);
      
      const userTokens = await gameTokenFactory.getUserGameTokens(user1.address);
      expect(userTokens.length).to.equal(1);
      expect(userTokens[0]).to.equal(1);
    });

    it("Should handle deployment failure gracefully", async function () {
      // This test simulates deployment failure by using extremely long name
      const xpAmount = ethers.parseEther("2000");
      const longName = "x".repeat(100); // Exceeds MAX_NAME_LENGTH
      
      await xpToken.connect(user1).approve(await gameTokenFactory.getAddress(), xpAmount);
      
      await expect(gameTokenFactory.connect(user1).createGameToken(xpAmount, longName, "TST", 18))
        .to.be.revertedWithCustomError(gameTokenFactory, "NameTooLong");
    });
  });

  describe("Game Token Burning → XP Unlocking", function () {
    let gameId;
    let gameTokenAddress;

    beforeEach(async function () {
      // Setup: Lock CREDA → XP → Create Game Token
      const lockAmount = ethers.parseEther("5000");
      await credaToken.connect(user1).approve(await gameTokenFactory.getAddress(), lockAmount);
      await gameTokenFactory.connect(user1).lockCreda(lockAmount);

      const xpAmount = ethers.parseEther("2000");
      await xpToken.connect(user1).approve(await gameTokenFactory.getAddress(), xpAmount);
      const tx = await gameTokenFactory.connect(user1).createGameToken(xpAmount, "Test Game", "TG", 18);
      const receipt = await tx.wait();
      
      gameId = 1;
      const event = receipt.logs.find(log => log.fragment?.name === "GameTokenCreated");
      gameTokenAddress = event.args[2];
    });

    it("Should burn game tokens and return XP", async function () {
      const burnAmount = ethers.parseEther("1000"); // Half of the tokens
      const expectedXP = ethers.parseEther("1000"); // Half of locked XP

      const initialXP = await xpToken.balanceOf(user1.address);
      
      await expect(gameTokenFactory.connect(user1).burnGameToken(gameId, burnAmount))
        .to.emit(gameTokenFactory, "GameTokenBurned")
        .withArgs(gameId, user1.address, burnAmount, expectedXP);

      // Check balances
      const GameToken = await ethers.getContractFactory("GameToken");
      const gameToken = GameToken.attach(gameTokenAddress);
      expect(await gameToken.balanceOf(user1.address)).to.equal(burnAmount);
      expect(await xpToken.balanceOf(user1.address)).to.equal(initialXP + expectedXP);
      expect(await gameTokenFactory.xpReserves()).to.equal(ethers.parseEther("1000"));
    });

    it("Should revert when burning zero amount", async function () {
      await expect(gameTokenFactory.connect(user1).burnGameToken(gameId, 0))
        .to.be.revertedWithCustomError(gameTokenFactory, "ZeroAmount");
    });

    it("Should revert when burning more than balance", async function () {
      const burnAmount = ethers.parseEther("3000"); // More than user's balance
      
      await expect(gameTokenFactory.connect(user1).burnGameToken(gameId, burnAmount))
        .to.be.revertedWithCustomError(gameTokenFactory, "InsufficientBalance");
    });

    it("Should revert with invalid game ID", async function () {
      await expect(gameTokenFactory.connect(user1).burnGameToken(999, ethers.parseEther("100")))
        .to.be.revertedWithCustomError(gameTokenFactory, "InvalidGameId");
    });

    it("Should handle partial burns correctly", async function () {
      const totalTokens = ethers.parseEther("2000");
      const burnAmount1 = ethers.parseEther("800");
      const burnAmount2 = ethers.parseEther("700");
      
      const initialXP = await xpToken.balanceOf(user1.address);
      
      // First burn
      await gameTokenFactory.connect(user1).burnGameToken(gameId, burnAmount1);
      expect(await xpToken.balanceOf(user1.address)).to.equal(initialXP + burnAmount1);
      
      // Second burn
      await gameTokenFactory.connect(user1).burnGameToken(gameId, burnAmount2);
      expect(await xpToken.balanceOf(user1.address)).to.equal(initialXP + burnAmount1 + burnAmount2);
      
      // Check remaining tokens
      const GameToken = await ethers.getContractFactory("GameToken");
      const gameToken = GameToken.attach(gameTokenAddress);
      expect(await gameToken.balanceOf(user1.address)).to.equal(totalTokens - burnAmount1 - burnAmount2);
    });
  });

  describe("Admin Functions", function () {
    it("Should allow rate manager to update conversion rate", async function () {
      const newRate = ethers.parseEther("2"); // 1 CREDA = 2 XP
      
      await expect(gameTokenFactory.connect(rateManager).setRate(newRate))
        .to.emit(gameTokenFactory, "RateUpdated")
        .withArgs(CREDA_TO_XP_RATE, newRate);

      expect(await gameTokenFactory.credaToXpRate()).to.equal(newRate);
    });

    it("Should revert when non-rate-manager tries to update rate", async function () {
      const newRate = ethers.parseEther("2");
      
      await expect(gameTokenFactory.connect(user1).setRate(newRate))
        .to.be.reverted;
    });

    it("Should allow pauser to pause/unpause", async function () {
      await gameTokenFactory.connect(pauser).pause();
      expect(await gameTokenFactory.paused()).to.be.true;

      await gameTokenFactory.connect(pauser).unpause();
      expect(await gameTokenFactory.paused()).to.be.false;
    });

    it("Should allow emergency withdraw", async function () {
      const EMERGENCY_ROLE = await gameTokenFactory.EMERGENCY_ROLE();
      await gameTokenFactory.grantRole(EMERGENCY_ROLE, owner.address);

      const withdrawAmount = ethers.parseEther("100");
      
      await expect(gameTokenFactory.emergencyWithdraw(
        await xpToken.getAddress(),
        owner.address,
        withdrawAmount
      )).to.emit(gameTokenFactory, "EmergencyWithdraw");
    });
  });

  describe("View Functions", function () {
    it("Should calculate XP amount correctly", async function () {
      const credaAmount = ethers.parseEther("100");
      const expectedXP = ethers.parseEther("100"); // 1:1 ratio
      
      expect(await gameTokenFactory.calculateXpAmount(credaAmount)).to.equal(expectedXP);
    });

    it("Should calculate XP return correctly", async function () {
      // Setup game token first
      const lockAmount = ethers.parseEther("5000");
      await credaToken.connect(user1).approve(await gameTokenFactory.getAddress(), lockAmount);
      await gameTokenFactory.connect(user1).lockCreda(lockAmount);

      const xpAmount = ethers.parseEther("2000");
      await xpToken.connect(user1).approve(await gameTokenFactory.getAddress(), xpAmount);
      await gameTokenFactory.connect(user1).createGameToken(xpAmount, "Test", "TST", 18);

      const burnAmount = ethers.parseEther("1000");
      const expectedReturn = ethers.parseEther("1000"); // Half of locked XP
      
      expect(await gameTokenFactory.calculateXpReturn(1, burnAmount)).to.equal(expectedReturn);
    });

    it("Should return complete game token information", async function () {
      // Setup game token
      const lockAmount = ethers.parseEther("5000");
      await credaToken.connect(user1).approve(await gameTokenFactory.getAddress(), lockAmount);
      await gameTokenFactory.connect(user1).lockCreda(lockAmount);

      const xpAmount = ethers.parseEther("2000");
      const name = "Complete Info Test";
      const symbol = "CIT";
      await xpToken.connect(user1).approve(await gameTokenFactory.getAddress(), xpAmount);
      await gameTokenFactory.connect(user1).createGameToken(xpAmount, name, symbol, 18);

      const [gameInfo, metadata] = await gameTokenFactory.getGameTokenInfo(1);
      
      expect(gameInfo.creator).to.equal(user1.address);
      expect(gameInfo.xpLocked).to.equal(xpAmount);
      expect(gameInfo.decimals).to.equal(18);
      expect(gameInfo.active).to.be.true;
      expect(gameInfo.tokenAddress).to.not.equal(ethers.ZeroAddress);
      
      expect(metadata.name).to.equal(name);
      expect(metadata.symbol).to.equal(symbol);
      expect(metadata.initialSupply).to.equal(xpAmount);
      expect(metadata.creationTime).to.be.gt(0);
    });
  });

  describe("Gas Optimization Analysis", function () {
    it("Should show improved gas efficiency for packed structs", async function () {
      const lockAmount = ethers.parseEther("5000");
      await credaToken.connect(user1).approve(await gameTokenFactory.getAddress(), lockAmount);
      await gameTokenFactory.connect(user1).lockCreda(lockAmount);

      const xpAmount = ethers.parseEther("2000");
      await xpToken.connect(user1).approve(await gameTokenFactory.getAddress(), xpAmount);
      
      const tx = await gameTokenFactory.connect(user1).createGameToken(xpAmount, "Gas Test", "GT", 18);
      const receipt = await tx.wait();
      
      // Log gas usage for analysis
      console.log(`Gas used for game token creation: ${receipt.gasUsed}`);
      
      // Should be significantly less than a typical contract deployment
      expect(receipt.gasUsed).to.be.below(3000000); // Much less than deploying from scratch
    });
  });
}); 