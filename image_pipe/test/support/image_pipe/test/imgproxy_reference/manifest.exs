%{
  sources: %{
    "border.png" => "350a6d992b4204dc619ccc492475ced70509b9f350fb7aed6f6156cb5efe1952",
    "small.png" => "517719b9e7ad77f867266b8c4e135d383cdc94c3bf14f7bc26c2060a98ae870a",
    "exif_placement_2.jpg" => "b4c47754f040d0fb6cd23d76576430dbabe760c7c2f698c9da30003f2708a9db",
    "exif_placement_3.jpg" => "7c7d36bec89cac720e78660b0ba4153f678a8d5ab0e254421c9c27626b98ae99",
    "alpha_border.png" => "539bb44e3d5279a6be9cbc29f46a3e7554285fbacf74433d146bb0df2233dacf",
    "icc_p3.png" => "80ce9bc055c01a12a9d8bf3db1693a1b46995f66bfdb796503636122de264869",
    "high_freq.webp" => "32d8e080d7e440b6329a441d2913222906d320bdeb060e956eb68a297c51df18",
    "alpha.png" => "7ef18f9ce1e08b6752fa8e55caf0819882d3779b997b65ec7a6c0c45e3a75fee",
    "exif_2.jpg" => "8756ad8af4a475b0f3a3a6899d9f4e4133fb6ba9db48de3de0351c0a89c41a47",
    "rgba16.png" => "0864f435451fd70d22779252fd5e6e5c4b69d0dd589133c069c3a18dad0ff45e",
    "strip.png" => "1408259edc2de06db7e79afa0854dd0134a010e4e99b57024a35b5dd61a0779e",
    "high_freq.jpg" => "54ded6c57ec02c685e275276b54947f8c9345015342fc8a2acc9d8e54e4a7d43",
    "marker.png" => "cbb47b49a36fc7a8b37233c862e1d4b88174ec6bf81876223779b4ce3c52120d",
    "exif_5.jpg" => "627dfc2290f56b47acffe53f25dcc6cedda9e51a28ae7ac815aba098d7add7f7",
    "palette.png" => "a963243e4caa27df9474da13a271ebd98a1313f07c5059045eeb264fb7192735",
    "exif_placement_5.jpg" => "dc1a15da0a2fa424750012054e8dd77e8513da21341172b6b63e1fdb07ed8c2e",
    "exif_placement_7.jpg" => "cd865146d6bcced1ee11cef5807ccb95dfe5051cf2df14ce39a724438899c11e",
    "exif_placement_8.jpg" => "c2705d93f917dc4c51b40ee8a01ca05b27ab7806d3a46636c26eedee8e1ae082",
    "exif_large_6.jpg" => "23e4d0ec736fcfd4377f807dd05057cb8105873d97f325e0d50aab09604e1f9b",
    "exif_3.jpg" => "1d1f1f82266ae21079b7da91a715f540e260f38a4aca56e99b6c2d40b1367ea4",
    "exif_8.jpg" => "51d5a8f471da85a76b6327bcc08afe22f55994001003d252f0c98e6540ffd023",
    "exif_6.jpg" => "ffc9f345632012165b7c80950b5d97999c370cc8f434995e52f58099fc675905",
    "gray_alpha.png" => "28559cda145886e515af31186b7e7a7ffc46b6c37a33c0bde7fa467199fb6d8e",
    "uniform.png" => "9a2f41e316022c247198d5266cc6a4a9858e94bd7b79a2df4461d51a3c5ac6ad",
    "rgb16.png" => "e0601a09f13020b00dd88e45794dd7fd59368239607c482609f027ee423d8119",
    "placement.png" => "eb3de4dce6337ed2bd531b35187bcda3265542dc5b661152631839616eca7d09",
    "cmyk.jpg" => "9888782df8ccd2e3654b430d6d9feb16985c381859688b22a54dc956772aad0c",
    "exif_7.jpg" => "e3e222be9871ff6064dd88d2fd0e6281f39b04183bf6960a8dc22dde82b4f976",
    "exif_placement_4.jpg" => "6416279f4061f5d7e8a532abde187611724ecc98cb27ed17931fda37d597a40f",
    "placement_odd.png" => "90ef7ea8a82a5f15b4b2e77cf757d7f6df0ff428be24a921e8ce8af0ca153204",
    "exif_4.jpg" => "b56080f10510693331c1cfb35028b401c7d8958505710ec3bdc098c2e4df7042",
    "border_asym.png" => "9782adfcd78b6033d6d97797bf76709fca200d5789491e4e8f080541e17b7ebd",
    "gray.png" => "5dbbff7926a2d0a99ad8f0519e311d79f9cd81428c804c6b6a9307780ff6293d",
    "exif_placement_6.jpg" => "647850a6d806cc8141574273bf8b4cf7cc76548331af2f00777b838dcdbb9d9f",
    "bitonal.png" => "1a8c31ead7499debf4110b48a8faf52932e62aa76ccf9c0c8cb403da34f17e84"
  },
  cases: %{
    "exif_cover_asym" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "7b7c895adfc90b4546f5dd82aeb22ab7b8a0eda59efa4c61718a58e9aaff0126"
    },
    "grav_soea" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "29439158c8bf45616731fbace2b9e1a439fc199070630c84aab89b88e52464d4"
    },
    "exif_2_crop_no" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "d3e9c6ddfe1c8546db919983898f9a1cce89cd5cfe8d74831142621482bf36dc"
    },
    "auto_resize_square_source_icc" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: %{
          description: "sP3C",
          sha256: "231752984cd4a5278e1b8d2390fe496767d4511fc81f54e1a5c69ae9ab4c42b5"
        },
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "5f2aca7ac0c4976cf10f39aefe5c551ced858b412d2966786383d486a51ed652"
    },
    "grav_noea_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "182ca208fc74158e4c101b3352c7c87eea3ce1b31ba6e3034f87420daa2950dc"
    },
    "dpr125_cover_odd_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "0080de9221f33aeee2cc17e1cdce554b55f38f9ac68ec3d49c0c3dfc9092dafa"
    },
    "exar_gravity_south_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "33f879ec91797827a19aff9a8134162103c5f8e9b154ae5d01e7a10458201028"
    },
    "cover_odd_gap_center_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "58eb1dd93b5541973c662cdbf3f7e3546ac7cc5fae0aa6f7f78116db1a643935"
    },
    "bitonal_crop" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 1,
        interpretation: :VIPS_INTERPRETATION_B_W,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "ad17e405c3f1de9f9cff3ed8ad1c732b14fd42fc4dd7d9c8ae9ce26869a569b9"
    },
    "rs_fill_zone_q4" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "ce37e1de5360ca35ac1407269a014e695a2ab484c0f55987839c18cd28659f0c"
    },
    "exif_extend_south" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "c69533dfb15e426ac760589bf0b6bbb8eab3e85d10e6d169e3ff12b927e1c3c9"
    },
    "wm_center_scaled" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "8cd42281b73269bd5422061b8dd9978c85dc2737307751e32a7164e25e72a2ae"
    },
    "grav_soea_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "42cdba3868e3a8585ec2781c0b1d220eceed857f7629c719b93d296db1d4891d"
    },
    "exif_cover_focal_transverse" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "14480d7856041f30bbae467229b0cd97dad0df335155348beb15de0900592720"
    },
    "crop_west_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "bdd71a80029e55b46cd367f719b958cb9d9eb8867745641f12e2b7f4335d55d3"
    },
    "exif_large_cover_offset" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "c3cd078235e260ca5f7836236643d036177e98694122c2f3de6ef2783b182eb0"
    },
    "wm_natural_size" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "b314ee26db6e34f86ab051fcf9da550ce52e5e8c9c29fb7432729a7591cc4cec"
    },
    "alpha_pixelate" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "35676bbc730bace1fa3e2abf2dd65a0540ff8c9c642095f72a7ab2af18008e64"
    },
    "trim_color_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "b996b43cc151cc430653ff4a67788fef9772ed5aba702b7afa8405b40b8f51b3"
    },
    "bg_hex_alpha" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "cdcaf41f0c8f64c3f76aa258be5789dea1cd6f7843e95230e10fd7099ce29713"
    },
    "strip_exif" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "79d98874795f31d33cb9c4739f7eb69f1b83c2e3b1096858f9ca126232db9322"
    },
    "extend_inert_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "bba860e367017abb1dcfc0797f5f581329399223baf36bd5ddb2ac59e79a8558"
    },
    "grav_ea_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "c83aeabe1453421a79b25c5f505f244337adf5a12e4d4b0ec72a66ece85d98b9"
    },
    "exif_5_extend_so" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "231caaba0f232ddb90d32a7c21b8378da1ca1e445737a3fec8777a46991ae945"
    },
    "webp_cover_offset" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "61c07055b217b92fa60fbf7d948b91a52173875b00393d50f4229431d05275c1"
    },
    "pixelate_odd_dims" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "18a817f797c2dbc2bfeff7f7a238cedcf0930ec598f67a538cc4077c192bd2e9"
    },
    "crop_offset_dpr_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "cdc7023e6f2d4cc112de67cfeebf47b23d2914e96ca99cc6f1f8c4390d15a8e1"
    },
    "ex_dominates_exar" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "c17cded72bf2ad1924f0646d3b6225e95a724c825cc43225b39ec01151002a18"
    },
    "crop_corner_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "780022203c06f158eb8545bd9690b121150b1dbb25519480b56f4f0b39fa40de"
    },
    "cover_gravity_south_offset_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "892457cfed820ba8fc335c32155c450230fa641860f6b94e57075532be6697f1"
    },
    "strip_fit_box" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "13a6ff1a7b3fb074970915f5ecc092eb8803afc4e3ac6a5217be5e0c159f7ff0"
    },
    "exif_extend_ratio" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "c3f478e0c89b23b281e8f7338ba5b4e401d67fe0044fe19615db3244ab8a8ecd"
    },
    "grav_ce_rel_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "b33090cff7904ff433f17c5ebd0d56e57df96668995c2de4e1ca639f00d43e75"
    },
    "gray_alpha_flatten" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 1,
        interpretation: :VIPS_INTERPRETATION_B_W,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "129ebac678cb75ba7a5bee7aff956b2677999dc6e51f112d5df734eccf8fa392"
    },
    "grav_so_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "580873e641a942c4b1fbdd4a61d5427075198e9fe7f1af8402ceb9c1ad4ce783"
    },
    "extend_gravity_north_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "cad8f380cd29378a0ff86ba270333033bc6cd4dbcdb3759ae88e2949b0c959f2"
    },
    "crop_larger_than_image" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "dd59be38f7dbc89f7cbb930d2b6f738ee418acea6469adb72943d72aabe1634e"
    },
    "extend_offset_east_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "99327146b129ba5b4bd2c80f1f5964d68e607ac87990b5f2cc5304ed4b6ee2b8"
    },
    "extend_padding_stack_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "d2802f1f15949d73b1ddf3b7ff0128def0382520875252af8b3e5955e78892a0"
    },
    "strip_fit_width" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "cecd70d085520f022e167dbf869e430aa591094d0b379e8ee37fe6ab22202b45"
    },
    "alpha_border_trim_symmetric" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "e9b1b1a02fc3d5f68fd274126f446a3630a0984c58a7f2b1f7af0d18a76cf401"
    },
    "trim_equal_h_exif5" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "356a11d4845340173e3ec149c165e1cd276dc0047050d0c5970c4b2cb646a038"
    },
    "alpha_blur" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "49637c72b4ebfb0a08333f320a7bc64c4d0ad18c16dc7215009c86a363a3269f"
    },
    "exif_5_cover_rot90" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "255202508ca2403b8307a2928b51178ced4c38a13745135760f75ac791005e50"
    },
    "cover_smart_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "3571ad4e89b9d6ad964d5dffd1fe6e4c763a50d7b7a2cb286c73b6d44d49dea3"
    },
    "cover_west_gravity_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "cc951096a398c2ae0347478e4604d8d63e0b2b707c42880be21800597bf36dd5"
    },
    "exif_7_cover_rot90" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "f6ced049d65c6f9b957fd0d739135d7deda98def7e6f928d9d5e585ed560486f"
    },
    "wm_dpr_scaled" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "bdb9955d7fd1f078d996201e66e3afe609e8c1109410cf1a35cdbda0ba1c088c"
    },
    "dpr15_extend_pad_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "055da8c136c573e9e1e80079980ddfd18d27ccb23867c800bbfd46199f961cb1"
    },
    "exif_4_crop_no" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "6d320fe78bd2cd98e8de1dea37bfa0c947a11fa5a25b0e72b8008acd49c51303"
    },
    "rgba16_preserve_hdr" => %{
      structure: %{
        depth: 16,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_RGB16,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "2eed28ab08e3dfb2fd4441fbe6570fa2b5c0cf94a3611a5ad547add2c0c043ee"
    },
    "exif_3_cover" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "bbe4adabd8293b548fa7933f110f6d65299af7b84d6ef21a5029b1e82d9ff8bd"
    },
    "exif_7_extend_so" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "209d4e4ea4fc451007ed1a3888db0a83336ecef84326f474f266b434619821e3"
    },
    "cover_enlarge_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "42898227a5d0777b7c724a96d8a71e6192db3568f02524a8f38bda3a17cf96fa"
    },
    "exif_crop_focal" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "6f7380739c9aa949e3102829cabe2ddaf9ca57ff6671abdcc83cbbd6ca43639d"
    },
    "exif_crop_north" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "1cfc70f3884009d60100aa6d83ae5cc5ddf101e03fb1b01964f59fa0a92a6080"
    },
    "crop_gravity_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "65c19f17fcf0110fa45ef5e46a77e3ca9d90f1f4f017f229019d3b16aa089ff3"
    },
    "exif_5_cover" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "2c5fdb339ee14be1fcc30d098ca80dca9e30cf09f48b68a33c11ce4d3ad2271b"
    },
    "user_rot180_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "25ec6ecdb9819a322dc873f4481293cdc9eff940c04e2fb39ef0983ed9961240"
    },
    "trim_equal_hv_border" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "e00a29a6c06e316258b52fb51795248503b7d2c25d48676bca3615b9d0e96bfc"
    },
    "palette_crop" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "e7575082f68a46fe2a1cb9da76138fb4722c18d9d6082bf949794148e51843c8"
    },
    "cover_odd_gap_corner_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "6ed5eef448f92392f943ee65bcae8f428828a7b4eaaa532fc0ae9d1ce2415f4a"
    },
    "rs_fill_zone" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "49067e71914e1ceb56b144d8eefe5c54c1caa2de724c1d1117d518715569c1e5"
    },
    "exif_5_crop_no" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "cb0ef932743dc2d6abe9688447ae8f2c795fae50225ff2a81779c0ccf52ab690"
    },
    "extend_ratio_already_matching" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "bba860e367017abb1dcfc0797f5f581329399223baf36bd5ddb2ac59e79a8558"
    },
    "grav_sowe_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "5568cd750bfb92d57cad44503714f02f945047e2563ebc2885f13d43a6ed12e6"
    },
    "exif_large_cover_focus" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "969d3ba2d53abcfd8c2f01bbcf28dd5e6d955a88fc0b411713bf956b7096b331"
    },
    "exif8_rot90_flip" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "636a89b11d99516b514f8b3174a499082c44008d0d59a71b02ae8a74931a3a5e"
    },
    "wm_on_padding" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "943744641965270d6ad5b0a3d5ad84d535b8745e98ca0df99a1e2f259f243a9d"
    },
    "exif_5_cover_fl" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "7b7c895adfc90b4546f5dd82aeb22ab7b8a0eda59efa4c61718a58e9aaff0126"
    },
    "extend_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "c17cded72bf2ad1924f0646d3b6225e95a724c825cc43225b39ec01151002a18"
    },
    "flip_hv_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "46d63bfaec6485ee1ddba5e3a60f968b414adabec1601c26c0cffa9dfa6f0534"
    },
    "dpr15_cover_offset_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "47851b26cfab3e08e0eb98a52fc3a08d9fe173b2da123889199a71d53a4a52cf"
    },
    "strip_extend" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "abd54baca1e62e0e1dcdd727a17cbedd0a998bfa93a2f5533bfe08ef3f7bc334"
    },
    "auto_resize_square_target_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "bd1ebd7079f7d41f861fa3249b43d1b290e30f913f14744d6b8c897d00b0c103"
    },
    "wm_relative_offset" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "eb5e5bde7f7fde2b3aef4370a95930aa8bee76f690f9b997f70d86ce8b9cf6c6"
    },
    "crop_inherit_grav_offset" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "c3753086394cdf7a5c01ae0dcc3c01c951b0246303a1252b5910418f30141868"
    },
    "wm_on_exif_frame" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "2f61673bc946adbda1805712575b428799094a676e0907e2900d8b9438cf3e02"
    },
    "exif_cover_smart" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "625bd1068976931776084d668647cf52f3003509c3057e6296fe431fdfe9ae8e"
    },
    "cover_offset_dpr_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "5eacf1059134d3a40971cee9b56b2af7e7d4635b646ecebe98e58feec9027293"
    },
    "rot270_crop_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "dbe064309f5c2e223b3ef95ab000f83205fef80c2d100009b35a7bcfc17a5e9b"
    },
    "cmyk_crop_blur" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "242ae88b750726a39ad1c76e08467be182c0083457574613afd408f9dfc15a5f"
    },
    "scp0_colorspace_124" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: %{
          description: "sP3C",
          sha256: "231752984cd4a5278e1b8d2390fe496767d4511fc81f54e1a5c69ae9ab4c42b5"
        },
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "90947f527cb71392f30558bf343b3e3cbddb516f73afecfba27a9518e30758f3"
    },
    "orient_none_rotate" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "4eecef2490469f0eef1a4f40756e981b2bb543f3796a8f0387e7d532eeee7c5f"
    },
    "uniform_trim" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "8f2f5d60510da6f36069f32adf5b6afe4f330c427e7a97f90e4c2ac03414cb18"
    },
    "trim_then_extend" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "b83a6db63891b98aa35e4d9700db62f657c5711e26b5c51766a18958e9042c09"
    },
    "alpha_sharpen" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "97ab7812476c27d18aa453e1765bdef40be200932de967d17d29798c42b364b8"
    },
    "gray_fit" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 1,
        interpretation: :VIPS_INTERPRETATION_B_W,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "e2b1812aef182ed525cb92a8d6bc34ecf9cf781ea6472c6be016ee0a47742296"
    },
    "exif_7_cover_fl" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "2b1b736ed8a03f337ee9405951199fa5e011402e40cd9c48e712b80cc25c69ab"
    },
    "exif_4_cover" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "f6ced049d65c6f9b957fd0d739135d7deda98def7e6f928d9d5e585ed560486f"
    },
    "exif_182_padding_no_resize" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "7671a296cc624b566b3526fa041ecb9bbf63d32c4a8917487b687d7aec732623"
    },
    "flip_v_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "d42e4551a3be362316d26269b302766a75a3ccdc3870bd18fd202ede1d841fd9"
    },
    "extend_ar_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "b228e4eb6c51b2ee76f132330567c629859803875ec544311bd070ae7bdb4b1d"
    },
    "pixelate_larger_than_image" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "41ef52277b074802198871a31a4f7aa20802e764d7aa3b712cc48d065de50af1"
    },
    "crop_east_offset_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "cdc7023e6f2d4cc112de67cfeebf47b23d2914e96ca99cc6f1f8c4390d15a8e1"
    },
    "extend_offset_clamp_dpr_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "563e2b027b051acda07cbfeca7577dfd3bda49ee6cea54a2cbe234b57ae75835"
    },
    "grav_so" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "e1d6133c192b8581eae0e87ccc2ec83c9a7a0e919c30f30b6ed330109e004b90"
    },
    "exif_large_cover_dpr" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "ac5063e2c64ddac6f86daeb199d771ea0d5ba6e41142f1d225499994df1c998f"
    },
    "grav_noea" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "ac77f8ef309cb4aab23b0f2fdd708a0d24c3f905a41f1fb99df078ef33a2d2fc"
    },
    "uniform_trim_resize" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "07843f34ae3d88e550075e44b5f1fe26d6996bb2fc0f7ead23b61527a925c8b6"
    },
    "bg_on_opaque" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "c55cd6309fa68b2e9244f3dbd9e0c18d62ef82f8392b42a968acdf3d0ff18b61"
    },
    "extend_ar_dpr_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "aa11c87e7f0ab3640e99e33fa8723fc0373a52dfb4fce1786e70ea5c1269db06"
    },
    "grav_ce" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "8c5f8a35d273d31a061054118d4149d61b5fda4100775333603c9bb867218127"
    },
    "extend_dpr_fractional_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "aa11c87e7f0ab3640e99e33fa8723fc0373a52dfb4fce1786e70ea5c1269db06"
    },
    "exif_7_cover" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "122320325795a93e90121504d8115ce5d10c5cb838ad823278c78733316714db"
    },
    "grav_we_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "73e3f0b5fbe124a79e4dede376fe331ef2a69d1b3d1e25bb06cb4ad2eec0638a"
    },
    "gray_extend_bg" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "1fd53166ff1bf20023d07545eb160669aa0e9e4adbf4e6ac824672d54e623645"
    },
    "trim_resize_high_freq" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "1470298dfbd3d677e9c6f4ad75f38445f48c5851f2e759dc3e63e1c257810d69"
    },
    "cover_corner_gravity_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "fe01761f16eea85fdcebe34db835579bad6c1adc428914e1d2c5190c7df48d54"
    },
    "crop_resize_two_gravities_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "03afc585b5e5abf85d5367a0c9a6ac907aa35b3adba4ee8f8417ceca7b566243"
    },
    "rot90_flip_h_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "3602aa2bb77f1d211b4943e282539533bb9323e14ed91cfac98a88960d84221f"
    },
    "zoom_dpr_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "8b3e08ab16576362a3f78ecdf07478b4b1cc95ef45a5bd077890d993db569b6c"
    },
    "orient_none_crop" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "ad8d8d14c983737e93056c3e1823d28d3f3feb3cb3e1983653f58ea9ab2ae9bc"
    },
    "extend_canvas_matching" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "bba860e367017abb1dcfc0797f5f581329399223baf36bd5ddb2ac59e79a8558"
    },
    "exif_7_crop_no" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "e9a1433b8c78bb2d0d6a66b0ac927cadaa3628c568dbe9c76ea80ff119337a13"
    },
    "exif_large_crop_fit" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "b70d4842792ee1ca8da0c7575843cdf8cc6e977221a55291c18e4347b3ed276f"
    },
    "alpha_extend_bg" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "cdcaf41f0c8f64c3f76aa258be5789dea1cd6f7843e95230e10fd7099ce29713"
    },
    "exif_large_fit" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "2cd0536964070e8501f3e905b8f104a0f6828500de0a542ce786778ae72e0c3a"
    },
    "exif_182_auto_branch" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "20ad2e78dec48eda5c7b9e18e9154c6350891841c122b376c7dce2f593cb7c4e"
    },
    "rs_fit_zone" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "eb4dfa2bee8f658209f2786c5d3a4518f84173209b55864568f233fd09c4be31"
    },
    "rot90_crop_north_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "8519282908a0245b01a1bc576c2dd6aff3636fd72e5d168f216722d73b9a3f49"
    },
    "trim_icc_p3" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "7e85fec8f86139fedf075753a2b2312a04d16f7d0bef0c74c17252caa90fc47f"
    },
    "crop_focal_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "e94d29d26fea3e9828f883d73b3a04b1cf311a831dcb89b108c2ff738c954628"
    },
    "rgb16_tonemap_8bit" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "c3b5c879c371810800afff4f44880a8c6d29e6a5f0bf1296343d0ba22aa0196f"
    },
    "resize_tail_enlarge_extend_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "8d7631377411352bb6dd7cde573eb082005f1a93567646ea22fa3dd38857f651"
    },
    "rot180_flip_hv_identity" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "a86807981299dd210cc507559a64002cf9668b8cb56adeddd55e2eb7657cd228"
    },
    "grav_no" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "f5aac4fb68af709ea600b4ee05ced38d54ae748daa89fcf851394501e6beea57"
    },
    "exif_cover_focal_transpose" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "fb59c994e0f6e4ee0e4fce41e3a7181c465b3a864a3999a2eb5bbb9a03c0a17f"
    },
    "gray_blur_pixelate" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "7a73d148b96adeb922f12a3f2dfe91be62fc0f03b3bfd4a082ac298fe9acf19d"
    },
    "crop_relative_dims_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "74ec816c74c1305442de87b6240744ef92bf19447405184875f30cff0a481f1e"
    },
    "enlarge_off_dpr_comp_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "dd59be38f7dbc89f7cbb930d2b6f738ee418acea6469adb72943d72aabe1634e"
    },
    "orient_none_cover" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "7fddd913ac395c2796ce9db79bc0cce5906fe07563e6598e73e158d721695d48"
    },
    "alpha_pad_transparent" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "d1b39d301061446606b451ca9fd0e1f9ffac4887731152da9c0c3f6c14a7d4d2"
    },
    "fill_down_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "2939a6d8a0de7382492f0f268b896e4663e75b63d5be6846b86248e9f8d6c8da"
    },
    "exif_8_extend_so" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "053a2a202bfa785721c8e9cd4fdb09b5a3d62934858c7d80fece6a94d9d82af5"
    },
    "wm_on_extended_canvas" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "0bde30a6c67a031d9b070f96d31b9b811f50e643efe0b49575644deeb69370b6"
    },
    "crop_relative_dims_odd_tie" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "a8ebca7df8186de2e21d1a0ac5619c0a7821cdbd545004d12e605f81a23e1909"
    },
    "scp0_blur_icc_p3" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: %{
          description: "sP3C",
          sha256: "231752984cd4a5278e1b8d2390fe496767d4511fc81f54e1a5c69ae9ab4c42b5"
        },
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "7cf152d49f9dfcc36766b5f08038fb9f28495c1de972f3cedbbac8ddb2c99895"
    },
    "cover_min_dims_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "58eb1dd93b5541973c662cdbf3f7e3546ac7cc5fae0aa6f7f78116db1a643935"
    },
    "padding_dpr_border" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "423ee3f25796212d24fab9eef6ad27de8f67fb62d69eeae973b2f893b37c2b15"
    },
    "palette_extend_bg" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "4709bac11ea7bd296f0855f2da401a8332f90c595cf0a6b5ff8c14e41d136579"
    },
    "resizing_type_direct_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "a2bb00551c4e82f9951c5437fbaee04b568c81fd916e3f84f5f326b173257e07"
    },
    "exif_8_cover" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "2b1b736ed8a03f337ee9405951199fa5e011402e40cd9c48e712b80cc25c69ab"
    },
    "wm_opacity_top_left" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "9bc7e31cc188f84a559e2716233ce21b58f52f76e22d7ab0ebebd9cc83f17f47"
    },
    "pixelate_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "522a35bf4f754db93a6d6816cf413c067a62cd11e2bee2fa4c0cb6c6de32f9e6"
    },
    "wm_corner_offset" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "7718275ee73f8d0e8e41fe0b5ea2ab08c4ce458288d1f59a35035af6b9230cdb"
    },
    "blur_zone" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "02e9f874b5b4bf5cf007a844040bc7e3806abdd55216d67e024b737a71c8ecd3"
    },
    "extend_corner_offset_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "d26cb97cf990f1a00ac95d0f40bf826f433cd7d344e5342a24b00ef77cdf601c"
    },
    "wm_tile" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "440dad7b71a573f5ec2df0173a8638499e020800dd7a8c71211014e53c0a9e60"
    },
    "rgb16_rotate_crop" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "ea5cdcb7e7bf8099697120173698d9b2e3bb03c89809c49aa9d86335440a06a6"
    },
    "dpr_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "e5fb54254c615ec898969e041fcb1e9e53fa3961045bd28ce846d899a520c0e1"
    },
    "exif_auto_square_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "a8b69e3cb2d73be56760aae2df633a33fb650f06a4f54fd7258a4363743872b9"
    },
    "fill_down_target_gt_source_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "86c67d8c5bbdb74b0e939795f0d825795b4a0fdd685995405bf5f9ddf043f376"
    },
    "resize_width_only_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "47851b26cfab3e08e0eb98a52fc3a08d9fe173b2da123889199a71d53a4a52cf"
    },
    "exif_182_auto_pad_dpr_cap" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "e713fdd73df5a83658c5d8a48217558753f647236f30d9a48828a3f5fd7bc48b"
    },
    "gray_alpha_fit" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 2,
        interpretation: :VIPS_INTERPRETATION_B_W,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "58343cb077449138d19e855e8ca1b7bf9f06f1064a0e961c39c04d316d4495db"
    },
    "extend_gravity_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "6f88a30a85bafce0da26d6f78481e833d2f3fab467ca69029b3b7dd84cd424e9"
    },
    "exif_3_extend_so" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "2f0389acb56d7c26683ddd6e00f0a240a45d97a2adb465d6773e927d123b0ed8"
    },
    "size_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "a2bb00551c4e82f9951c5437fbaee04b568c81fd916e3f84f5f326b173257e07"
    },
    "sharpen_zone" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "ad6fb7b30b6afe83d7bd7c808d010cdd5f06feef5088b54a8ea6b6c8adaae7ee"
    },
    "gray_pad_bg" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 1,
        interpretation: :VIPS_INTERPRETATION_B_W,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "ff7deb860185486890a6cc761ea7c83a246aee891703def11ef9f111c9d70600"
    },
    "alpha_resize" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "4423b7a96fff78ba10be919543ea7d515067da45c83fdaa7c59add65b47357f6"
    },
    "exif_2_cover" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "255202508ca2403b8307a2928b51178ced4c38a13745135760f75ac791005e50"
    },
    "grav_sowe" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "8adfabe6abf936711caa1c5346faf10d4c89eedfab9f24fce7b517304f9be38d"
    },
    "exif_user_flip_h" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "356a11d4845340173e3ec149c165e1cd276dc0047050d0c5970c4b2cb646a038"
    },
    "alpha_cover_crop" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "4534039625707327333bd4d977b2285a6f0d4feb66e94f6d5666e51c3899ecd1"
    },
    "exif_8_crop_no" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "99449d7cdf5c29395b041ad60fbcb92aa5eebe7deddd3f0bbf32da59fe2f324d"
    },
    "lossy_webp" => %{
      width: 240,
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/webp",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      height: 180,
      content_type: "image/webp"
    },
    "padding_border" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "1af6ead813738e1c08a94d74bb5901bbe999da983a6e9b3a7f84d082ac1ddf31"
    },
    "zoom_offset_no_scale" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "35334171012f49dbaf4ca819b88ab02b17529de5aeb59f4b90eb70d4babf814f"
    },
    "trim_then_pct_crop" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "a9f94fd367a9ca0f371b66c0d411375dbcb93ef3d77e76a612cfe44acd5d3ff9"
    },
    "trim_border_equal" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "f25e7af1bf08e3df79b6ace82515d7276dc92575f96006f24d37b3b72bf48336"
    },
    "gravity_offset_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "a6cb42f915db8661374325d8e85931017c9d881ba5617331ec7737108a13e44c"
    },
    "lossy_jpeg_q40" => %{
      width: 240,
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/jpeg",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      height: 180,
      content_type: "image/jpeg"
    },
    "grav_nowe_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "0b228be1541dc6b840d455aa2669c79de9472d3a7e1e0fbdc059a01ca50de663"
    },
    "gray_alpha_blur" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "3f86257c2d33310e71734081103b278425b8e445b496bbf3f759edb9b6f1489d"
    },
    "rgba16_blur" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "864762a093bf7a6b1e47a9f09a33221fc247c3fd0018ec23b74de23aa484b22f"
    },
    "grav_no_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "c3753086394cdf7a5c01ae0dcc3c01c951b0246303a1252b5910418f30141868"
    },
    "exif_2_extend_so" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "ef29ecd2a6a9aca14bd72650ede278c87f530c6b97cdef6b6935ab52f5d70369"
    },
    "effects_chain_order_high_freq" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "6dabd60fea767033d02075a8815bdabf88f716dbbe1cb3630a108c654e14a203"
    },
    "cover_corner_offset_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "ccf45e04748c551df84836fca2712b604275bbd5c50fda3d76848d18d31aa1d4"
    },
    "exif_182_pixelate" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "7577068b53ddba0d274e4ee20a22092dcf39e2e233edd781de3945f789ec0102"
    },
    "bitonal_fit" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 1,
        interpretation: :VIPS_INTERPRETATION_B_W,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "decc73c19ebc804e3f438d47ac777244201391a5d83c6553ff32ea5adb748026"
    },
    "alpha_border_trim" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "e9b1b1a02fc3d5f68fd274126f446a3630a0984c58a7f2b1f7af0d18a76cf401"
    },
    "zoom_padding_no_scale" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "91b109d0aedc3142ab9cd8bb8c6fc595b099c59b629654799c66d64bba40575d"
    },
    "crop_focal_edge_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "df84ba1da81c487987375ed885001ffc724a314e887071bef3ba2ff016bb588b"
    },
    "cmyk_import" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "3edbf150cac23cb36ddcc60e59b6bc2f8657abed560cbebd3c76dec8d0138799"
    },
    "cover_odd_gap_corner_dpr_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "1a36b442593a4c27919fe48d5192a60a26a2a9f08e5cf40f9cabd7d8039230ba"
    },
    "exif3_rot180_identity" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "641717dd8dba1e239099c42c01d8a000f687c202cc57f4140e4a9b41abd84a0e"
    },
    "flip_h_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "97a92326a2223a93ba24e7bc7c793c000e848a50afaa1ece4c392c97d80c01f2"
    },
    "bitonal_pixelate" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "d0f00806d67229f79994dac960e94ed8892df757019ed034fe001dcea9b276dd"
    },
    "crop_smart_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "89c3c63fc4b6c8580ec5e62a72a27fec124fa0b9cad63a7a794a6cf44638bf25"
    },
    "extend_offset_dpr_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "68adbb1be71963d2036f2e0535843bd9a0bd8fa3721ee4744ed627266a8b6f91"
    },
    "zoom_cover_resultcrop_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "786b2dbc90f92ae5cbb6d1291af3cfdda657e7f0b38f17d4e4472587ca7eb751"
    },
    "cover_focal_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "3571ad4e89b9d6ad964d5dffd1fe6e4c763a50d7b7a2cb286c73b6d44d49dea3"
    },
    "grav_we" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "19b03f87ecea0020a6d281a699b174c9a963312b7de138f31477afd60508675c"
    },
    "rgb16_preserve_hdr" => %{
      structure: %{
        depth: 16,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_RGB16,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "e21e3b68d09819003d2fa0cbe46e70c665fb53ba375cd4d21558eb11b1177110"
    },
    "exif_user_rot90" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "affcf95a6c6eea6fd2f79027f8490292617369a9cfa81b24d47286a0cafc86ef"
    },
    "grav_nowe" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "0ab4eb180619392ae26411bc8850d9d45d8daa7ca8e659a1d6485378c8750386"
    },
    "gray_alpha_rotate" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 2,
        interpretation: :VIPS_INTERPRETATION_B_W,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "9d4f6dfa80e36ff8a9095ccd0bf8b389aeda32114c74b2f994ef8b4295e408eb"
    },
    "rs_fill_webp_residual" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "9a384d245050b259bcd38efdf8c480caaf570bdc112149c5cd4917b432916332"
    },
    "rgba16_tonemap_8bit" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "2c508acf5cbe33eb4f2519cb72efbc4a04c5c6786f7c0e1791ede65a9bcc6b69"
    },
    "force_resize_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "b9a1442e44341fdc7023896be69f33159e0ed1c8b7e0e9647d4b27c9ef83cc02"
    },
    "wm_on_alpha_frame" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "04571e74cd023abf509d2e186f5c7efe71f0cad150acaaa660d0df15055ab963"
    },
    "pixelate_odd_exif7" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "6c42c1b9fd142b5dc42bfb587d6490b1c823a26c970dd7d7e2ca00b38a631bdb"
    },
    "crop_offset_out_of_bounds" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "8d25328983713e867a0147472216fe44d2dac8d4955d4c809431cf0cdfaf865b"
    },
    "fill_down_corner_gravity_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "81e505a01f3d56b81a62745684eb071abe8dac60c6ca7772e687fb0b983e75f6"
    },
    "auto_resize_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "c55cd6309fa68b2e9244f3dbd9e0c18d62ef82f8392b42a968acdf3d0ff18b61"
    },
    "grav_ea" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "a48b1dcdf9b4e9101eef6043c1c1a0e3661fe3dde1f00ff8a9ba5508eede530f"
    },
    "dpr15_fit_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "47851b26cfab3e08e0eb98a52fc3a08d9fe173b2da123889199a71d53a4a52cf"
    },
    "gray_watermark" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "d1b8d609ac1254cab43b1db30118afeb09618d7d2c795d1b820a097482285d99"
    },
    "crop_full_axis_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "d2727e0883ca0e97c2f49ae5a67a139d49f97b0ac88a09bdcc466dc6bd5405cf"
    },
    "enlarge_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "566e927840c7a479afe63b1042d32bdd2df82edce0230e3a3c573a42e00c65ce"
    },
    "width_only_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "47851b26cfab3e08e0eb98a52fc3a08d9fe173b2da123889199a71d53a4a52cf"
    },
    "alpha_border_trim_pad" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "7815c3a179a3daf5bfd9e2edea55bbe0847a2dd31d9d5bd72550ad73579c7b57"
    },
    "rotate_exif" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "79d98874795f31d33cb9c4739f7eb69f1b83c2e3b1096858f9ca126232db9322"
    },
    "dpr15_crop_offset_placement" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "cdc7023e6f2d4cc112de67cfeebf47b23d2914e96ca99cc6f1f8c4390d15a8e1"
    },
    "gray_alpha_trim" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 2,
        interpretation: :VIPS_INTERPRETATION_B_W,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "43a5a857a8161396b6970038f0aaad68aff7c3ca6cd04d928981b922fe5791ca"
    },
    "exif_4_extend_so" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "f0faef7ede4bbe5e4f7593bf8127b2cc336a4df88752c4f50efc77826dfccf19"
    },
    "enlarge_off_dpr_extend_small" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "910aa810c9314da456f1a9f13506e2b49561180cf859741333011706d9726a2e"
    },
    "palette_fit" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "c8fc787c65a7dbe6af2aacf1feaba245f7af5eb7e706ab4cde277c0d0b488ab8"
    },
    "grav_ce_off" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "9fa1b4c9fe2661ae107ed97911b02365ab3bdb4b27a63e098b8ab4be16435f5a"
    },
    "trim_exif_cover_crop" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "999a7afcfdf58f5dc19ac0b48cc2ab55d364790074b724456842d9bb67c4a74d"
    },
    "background_alpha" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "cdcaf41f0c8f64c3f76aa258be5789dea1cd6f7843e95230e10fd7099ce29713"
    },
    "lossy_avif" => %{
      width: 240,
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/avif",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: nil,
        alpha?: false
      },
      height: 180,
      content_type: "image/avif"
    },
    "cover_rel_offset_dpr_marker" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "781e18414afe7ea6005a01834ad6847d447e304ff94cb9096663637f750fa180"
    },
    "exif_3_crop_no" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 3,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: false
      },
      fixture_sha256: "72c0684d1cd41a0069acac6f408ec1a87fe6a1041ef7c2dac33c36776d439f0b"
    },
    "gray_alpha_extend" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 2,
        interpretation: :VIPS_INTERPRETATION_B_W,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "42b08c5f86846e4e0eb01cb29a6e4a89b709db50fb732bb94c41b85a1921ab1e"
    },
    "alpha_rotate90" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "35676bbc730bace1fa3e2abf2dd65a0540ff8c9c642095f72a7ab2af18008e64"
    },
    "alpha_flip_h" => %{
      structure: %{
        depth: 8,
        metadata: [],
        icc: nil,
        content_type: "image/png",
        bands: 4,
        interpretation: :VIPS_INTERPRETATION_sRGB,
        orientation: 1,
        alpha?: true
      },
      fixture_sha256: "35676bbc730bace1fa3e2abf2dd65a0540ff8c9c642095f72a7ab2af18008e64"
    }
  },
  imgproxy_image:
    "darthsim/imgproxy:v4.0.17@sha256:db0b4b9cd690c8b3590203dea300fb759a18c4ec2af7b37424f0bdef23ce317d",
  imgproxy_libvips: "42.20.7"
}
