import Dotenv from "dotenv";

import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-waffle";
import "@nomiclabs/hardhat-etherscan";
import "@typechain/hardhat";
import "hardhat-deploy";
import "hardhat-abi-exporter";
import "hardhat-artifactor";
import "hardhat-contract-sizer";
import "hardhat-dependency-compiler";
import "hardhat-docgen";
import "hardhat-gas-reporter";
import "hardhat-spdx-license-identifier";

Dotenv.config();
Dotenv.config({ path: "./.env.secret" });

const {
  API_KEY_ALCHEMY,
  API_KEY_ETHERSCAN,
  API_KEY_COINMARKETCAP,
  PRIVATE_KEY_MAINNET,
  PRIVATE_KEY_RINKEBY,
  REPORT_GAS,
} = process.env;

export default {
  solidity: {
    compilers: [
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: "0.4.18",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },

  paths: {
    cache: "./cache",
  },

  networks: {
    mainnet: {
      url: `https://eth-mainnet.alchemyapi.io/v2/${API_KEY_ALCHEMY}`,
      accounts: [PRIVATE_KEY_MAINNET],
      timeout: 100000,
    },
    rinkeby: {
      url: `https://eth-rinkeby.g.alchemy.com/v2/${API_KEY_ALCHEMY}`,
      accounts: [PRIVATE_KEY_RINKEBY],
      blockGasLimit: 120000000000,
      timeout: 300000,
    },
  },

  abiExporter: {
    runOnCompile: true,
    path: "./abi",
    clear: true,
    flat: true,
  },

  docgen: {
    runOnCompile: false,
    clear: true,
  },

  etherscan: {
    apiKey: {
      mainnet: API_KEY_ETHERSCAN,
    },
  },

  gasReporter: {
    currency: "USD",
    gasPrice: 100,
    enabled: REPORT_GAS ? true : false,
    coinmarketcap: API_KEY_COINMARKETCAP,
    maxMethodDiff: 10,
  },

  spdxLicenseIdentifier: {
    overwrite: false,
    runOnCompile: true,
  },

  typechain: {
    alwaysGenerateOverloads: true,
    outDir: "typechain",
    target: "ethers-v5",
  },

  mocha: {
    timeout: 60000,
  },
};
