require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      },
      viaIR: true,
      evmVersion: "paris"
    }
  },
  networks: {
    hardhat: {},
    megaethTestnet: {
      url: process.env.RPC_URL || "https://carrot.megaeth.com/rpc",
      chainId: 6342,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : []
    }
  },
  etherscan: {
    apiKey: {
      megaethTestnet: "empty"
    },
    customChains: [
      {
        network: "megaethTestnet",
        chainId: 6342,
        urls: {
          apiURL: "https://megaeth-testnet.blockscout.com/api",
          browserURL: "https://megaeth-testnet.blockscout.com"
        }
      }
    ]
  }
};
