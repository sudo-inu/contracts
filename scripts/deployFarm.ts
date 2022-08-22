import { ethers } from "hardhat";

import {
  DefaultController__factory,
  SudoController__factory,
  SudoInuLP__factory,
  SudoInu__factory,
  SnackToken__factory,
  SnackShack__factory,
  WrappedXminu__factory,
  MockERC20__factory,
  SqrtMath__factory,
} from "../typechain";

enum PoolType {
  TOKEN = 0,
  NFT = 1,
  TRADE = 2,
}

enum FarmType {
  STANDARD = 0,
  SCALED = 1,
}

const RINKEBY_FACTORY = "0xcB1514FE29db064fa595628E0BFFD10cdf998F33";
const RINKEBY_LINEAR_CURVE = "0x3764b9FE584719C4570725A2b5A2485d418A186E";
const RINKEBY_EXPONENTIAL_CURVE = "0xBc6760B11e433D25aAf5c8fCBC6cE99b14aC5D52";
const RINKEBY_SUDO_TEST_NFT = "0x09972358feEb111C0E1388161C3FA5e0Cd220A6B";

async function main() {
  const [deployer] = await ethers.getSigners();

  const buySpotPrice = ethers.utils.parseEther("0.05");
  const sellSpotPrice = ethers.utils.parseEther("0.1");

  // Mock ERC-20
  const fakeSnackXmonLpToken = await new MockERC20__factory(deployer).deploy(
    "XMON/SNACK LP",
    "UNI-V2"
  );
  await fakeSnackXmonLpToken.deployed();
  console.log("Fake XMON/SNACK LP: ", fakeSnackXmonLpToken.address);

  const fakeXmonToken = await new MockERC20__factory(deployer).deploy(
    "XMON",
    "XMON"
  );
  await fakeXmonToken.deployed();
  console.log("Fake XMON: ", fakeXmonToken.address);

  // ERC-20
  const snackToken = await new SnackToken__factory(deployer).deploy();
  await snackToken.deployed();
  console.log("SNACK: ", snackToken.address);

  // ERC-721
  const xminuNft = await new SudoInu__factory(deployer).deploy();
  await xminuNft.deployed();
  console.log("XMINU NFT: ", xminuNft.address);

  // Wrapped ERC-721 as ERC-20
  const wrappedXminu = await new WrappedXminu__factory(deployer).deploy(
    xminuNft.address
  );
  await wrappedXminu.deployed();
  console.log("Wrapped XMINU ERC20: ", wrappedXminu.address);

  // Buy LP Token
  const sudoInuBuyWallLp = await new SudoInuLP__factory(deployer).deploy({
    nft: RINKEBY_SUDO_TEST_NFT,
    factory: RINKEBY_FACTORY,
    curve: RINKEBY_LINEAR_CURVE,
    poolType: PoolType.TOKEN,
    spotPrice: buySpotPrice,
    allowFractional: true,
  });
  await sudoInuBuyWallLp.deployed();
  console.log("Sudo INU Buy Wall LP: ", sudoInuBuyWallLp.address);

  // Sell LP Token
  const sudoInuHighFeeTradeLp = await new SudoInuLP__factory(deployer).deploy({
    nft: RINKEBY_SUDO_TEST_NFT,
    factory: RINKEBY_FACTORY,
    curve: RINKEBY_EXPONENTIAL_CURVE,
    poolType: PoolType.TRADE,
    spotPrice: sellSpotPrice,
    allowFractional: true,
  });
  await sudoInuHighFeeTradeLp.deployed();
  console.log("Sudo INU High Fee Sell LP: ", sudoInuHighFeeTradeLp.address);

  const sqrtMath = await new SqrtMath__factory(deployer).deploy();
  await sqrtMath.deployed();

  // Farm
  const snackShack = await new SnackShack__factory(
    { ["contracts/lib/SqrtMath.sol:SqrtMath"]: sqrtMath.address },
    deployer
  ).deploy(snackToken.address, deployer.address);
  await snackShack.deployed();
  console.log("Snack Shack Farm: ", snackShack.address);

  // Controllers
  const defaultController = await new DefaultController__factory(
    deployer
  ).deploy(snackShack.address);
  await defaultController.deployed();
  console.log("Default Controller: ", defaultController.address);

  const buyWallController = await new SudoController__factory(
    { ["contracts/lib/SqrtMath.sol:SqrtMath"]: sqrtMath.address },
    deployer
  ).deploy(
    snackShack.address,
    sudoInuBuyWallLp.address,
    0, // 0% fee
    0, // 0% delta
    buySpotPrice,
    ethers.utils.parseEther("0.0000001") // 0.0000001 delta per 1 ETH of liquidity
  );
  await buyWallController.deployed();
  console.log("Buy Wall Controller: ", buyWallController.address);

  const highFeeTradeController = await new SudoController__factory(
    { ["contracts/lib/SqrtMath.sol:SqrtMath"]: sqrtMath.address },
    deployer
  ).deploy(
    snackShack.address,
    sudoInuHighFeeTradeLp.address,
    ethers.utils.parseEther("0.06"), // 6% fee
    ethers.utils.parseEther("1.05"), // 5% delta
    sellSpotPrice,
    ethers.utils.parseEther("0.0000001") // 0.0000001 delta per 1 ETH of liquidity
  );
  await highFeeTradeController.deployed();
  console.log("Exponential Sell Controller: ", highFeeTradeController.address);

  await snackToken.transferOwnership(snackShack.address);
  console.log("Transferred SNACK ownership to Snack Shack Farm");

  await timeoutPromise(10000);

  await snackShack.add(
    1000,
    FarmType.STANDARD,
    fakeSnackXmonLpToken.address,
    ethers.constants.AddressZero,
    defaultController.address
  );
  console.log("PID 0: ", await fakeSnackXmonLpToken.name());
  await timeoutPromise(10000);

  await fakeSnackXmonLpToken.mint(
    deployer.address,
    ethers.utils.parseEther("10")
  );
  console.log("Minted: ", await fakeSnackXmonLpToken.name());
  await timeoutPromise(10000);

  await snackShack.add(
    150,
    FarmType.STANDARD,
    wrappedXminu.address,
    ethers.constants.AddressZero,
    defaultController.address
  );
  console.log("PID 1: ", await wrappedXminu.name());
  await timeoutPromise(10000);

  await xminuNft.mint();
  console.log("Minted: ", await wrappedXminu.name());
  await timeoutPromise(10000);

  await snackShack.add(
    150,
    FarmType.STANDARD,
    snackToken.address,
    ethers.constants.AddressZero,
    defaultController.address
  );
  console.log("PID 2: ", await snackToken.name());
  await timeoutPromise(10000);

  await snackShack.add(
    250,
    FarmType.SCALED,
    sudoInuBuyWallLp.address,
    ethers.constants.AddressZero,
    buyWallController.address
  );
  console.log("PID 3: ", await sudoInuBuyWallLp.name(), "BUY");
  await timeoutPromise(10000);

  await snackShack.add(
    100,
    FarmType.SCALED,
    sudoInuHighFeeTradeLp.address,
    ethers.constants.AddressZero,
    highFeeTradeController.address
  );
  console.log("PID 4: ", await sudoInuHighFeeTradeLp.name(), "SELL");
}

function timeoutPromise(timeout: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, timeout);
  });
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
