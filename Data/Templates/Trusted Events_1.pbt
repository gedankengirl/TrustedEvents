Assets {
  Id: 312441181075307109
  Name: "Trusted Events"
  PlatformAssetType: 5
  TemplateAsset {
    ObjectBlock {
      RootId: 2433067020352864721
      Objects {
        Id: 2433067020352864721
        Name: "TemplateBundleDummy"
        Transform {
          Location {
          }
          Rotation {
          }
          Scale {
            X: 1
            Y: 1
            Z: 1
          }
        }
        Folder {
          BundleDummy {
            ReferencedAssets {
              Id: 15711733878564221137
            }
          }
        }
      }
    }
    PrimaryAssetId {
      AssetType: "None"
      AssetId: "None"
    }
  }
  Marketplace {
    Id: "ab9d4013b73c4e88a3073c18b29986c7"
    OwnerAccountId: "eec0239c0d644f5bb9f59779307edb17"
    OwnerName: "zoonior"
    Description: "== TrustedEvents is a drop-in replacement for Core Events.\r\n\r\nThey are:\r\n\r\n  * reliable: have a 100%(*) guarantee to be delivered in the order in which they\r\n    were sent, even if the connection is bad and network packets are lost.\r\n\r\n  * economical: they don\342\200\231t spend the already low\r\n    Events.BrodcastToPlayer/BrodcastToServer budgets.\r\n\r\n  * flexible: you can send *hundreds* of small events per second, or several\r\n    big ones. You have an option to send events either reliably or unreliably.\r\n\r\n  * convenient: all dispatched events are queued; no need to check return\r\n    codes and use Task.Wait.\r\n\r\nv.1 - Proof of concept\r\nv.2 - new client API that mimics Core Events, add Client-to-Server events, UnreliableBroadcastToAllPlayers "
  }
  SerializationVersion: 91
}
