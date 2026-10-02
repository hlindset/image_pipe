%{
  sources: %{
    "alpha.png" => "7ef18f9ce1e08b6752fa8e55caf0819882d3779b997b65ec7a6c0c45e3a75fee",
    "border.png" => "350a6d992b4204dc619ccc492475ced70509b9f350fb7aed6f6156cb5efe1952",
    "border_asym.png" => "9782adfcd78b6033d6d97797bf76709fca200d5789491e4e8f080541e17b7ebd",
    "cmyk.jpg" => "9888782df8ccd2e3654b430d6d9feb16985c381859688b22a54dc956772aad0c",
    "exif_2.jpg" => "8756ad8af4a475b0f3a3a6899d9f4e4133fb6ba9db48de3de0351c0a89c41a47",
    "exif_3.jpg" => "1d1f1f82266ae21079b7da91a715f540e260f38a4aca56e99b6c2d40b1367ea4",
    "exif_4.jpg" => "b56080f10510693331c1cfb35028b401c7d8958505710ec3bdc098c2e4df7042",
    "exif_5.jpg" => "627dfc2290f56b47acffe53f25dcc6cedda9e51a28ae7ac815aba098d7add7f7",
    "exif_6.jpg" => "ffc9f345632012165b7c80950b5d97999c370cc8f434995e52f58099fc675905",
    "exif_7.jpg" => "e3e222be9871ff6064dd88d2fd0e6281f39b04183bf6960a8dc22dde82b4f976",
    "exif_8.jpg" => "51d5a8f471da85a76b6327bcc08afe22f55994001003d252f0c98e6540ffd023",
    "exif_placement_2.jpg" => "b4c47754f040d0fb6cd23d76576430dbabe760c7c2f698c9da30003f2708a9db",
    "exif_placement_3.jpg" => "7c7d36bec89cac720e78660b0ba4153f678a8d5ab0e254421c9c27626b98ae99",
    "exif_placement_4.jpg" => "6416279f4061f5d7e8a532abde187611724ecc98cb27ed17931fda37d597a40f",
    "exif_placement_5.jpg" => "dc1a15da0a2fa424750012054e8dd77e8513da21341172b6b63e1fdb07ed8c2e",
    "exif_placement_6.jpg" => "647850a6d806cc8141574273bf8b4cf7cc76548331af2f00777b838dcdbb9d9f",
    "exif_placement_7.jpg" => "cd865146d6bcced1ee11cef5807ccb95dfe5051cf2df14ce39a724438899c11e",
    "exif_placement_8.jpg" => "c2705d93f917dc4c51b40ee8a01ca05b27ab7806d3a46636c26eedee8e1ae082",
    "high_freq.jpg" => "54ded6c57ec02c685e275276b54947f8c9345015342fc8a2acc9d8e54e4a7d43",
    "high_freq.webp" => "32d8e080d7e440b6329a441d2913222906d320bdeb060e956eb68a297c51df18",
    "icc_p3.png" => "80ce9bc055c01a12a9d8bf3db1693a1b46995f66bfdb796503636122de264869",
    "marker.png" => "cbb47b49a36fc7a8b37233c862e1d4b88174ec6bf81876223779b4ce3c52120d",
    "placement.png" => "eb3de4dce6337ed2bd531b35187bcda3265542dc5b661152631839616eca7d09",
    "placement_odd.png" => "90ef7ea8a82a5f15b4b2e77cf757d7f6df0ff428be24a921e8ce8af0ca153204",
    "rgb16.png" => "e0601a09f13020b00dd88e45794dd7fd59368239607c482609f027ee423d8119",
    "rgba16.png" => "0864f435451fd70d22779252fd5e6e5c4b69d0dd589133c069c3a18dad0ff45e",
    "small.png" => "517719b9e7ad77f867266b8c4e135d383cdc94c3bf14f7bc26c2060a98ae870a"
  },
  imgproxy_digest: "sha256:9ed8f87b34d55c7844951ff65bcf6605de54ba6670f64951c7215f9b125a482e",
  imgproxy_libvips: "42.20.2",
  cases: %{
    "exif_cover_asym" => %{
      fixture_sha256: "7b7c895adfc90b4546f5dd82aeb22ab7b8a0eda59efa4c61718a58e9aaff0126"
    },
    "grav_soea" => %{
      fixture_sha256: "29439158c8bf45616731fbace2b9e1a439fc199070630c84aab89b88e52464d4"
    },
    "exif_2_crop_no" => %{
      fixture_sha256: "d3e9c6ddfe1c8546db919983898f9a1cce89cd5cfe8d74831142621482bf36dc"
    },
    "auto_resize_square_source_icc" => %{
      fixture_sha256: "de43f58c1197c1a2a56208766929c0f78ef51ef5c0add07f3e61ab97756fc6fb"
    },
    "grav_noea_off" => %{
      fixture_sha256: "182ca208fc74158e4c101b3352c7c87eea3ce1b31ba6e3034f87420daa2950dc"
    },
    "exar_gravity_south_small" => %{
      fixture_sha256: "33f879ec91797827a19aff9a8134162103c5f8e9b154ae5d01e7a10458201028"
    },
    "cover_odd_gap_center_marker" => %{
      fixture_sha256: "58eb1dd93b5541973c662cdbf3f7e3546ac7cc5fae0aa6f7f78116db1a643935"
    },
    "rs_fill_zone_q4" => %{
      fixture_sha256: "ce37e1de5360ca35ac1407269a014e695a2ab484c0f55987839c18cd28659f0c"
    },
    "exif_extend_south" => %{
      fixture_sha256: "c69533dfb15e426ac760589bf0b6bbb8eab3e85d10e6d169e3ff12b927e1c3c9"
    },
    "grav_soea_off" => %{
      fixture_sha256: "42cdba3868e3a8585ec2781c0b1d220eceed857f7629c719b93d296db1d4891d"
    },
    "exif_cover_focal_transverse" => %{
      fixture_sha256: "14480d7856041f30bbae467229b0cd97dad0df335155348beb15de0900592720"
    },
    "crop_west_placement" => %{
      fixture_sha256: "bdd71a80029e55b46cd367f719b958cb9d9eb8867745641f12e2b7f4335d55d3"
    },
    "trim_color_marker" => %{
      fixture_sha256: "b996b43cc151cc430653ff4a67788fef9772ed5aba702b7afa8405b40b8f51b3"
    },
    "bg_hex_alpha" => %{
      fixture_sha256: "cdcaf41f0c8f64c3f76aa258be5789dea1cd6f7843e95230e10fd7099ce29713"
    },
    "strip_exif" => %{
      fixture_sha256: "79d98874795f31d33cb9c4739f7eb69f1b83c2e3b1096858f9ca126232db9322"
    },
    "extend_inert_marker" => %{
      fixture_sha256: "bba860e367017abb1dcfc0797f5f581329399223baf36bd5ddb2ac59e79a8558"
    },
    "grav_ea_off" => %{
      fixture_sha256: "c83aeabe1453421a79b25c5f505f244337adf5a12e4d4b0ec72a66ece85d98b9"
    },
    "exif_5_extend_so" => %{
      fixture_sha256: "231caaba0f232ddb90d32a7c21b8378da1ca1e445737a3fec8777a46991ae945"
    },
    "crop_offset_dpr_placement" => %{
      fixture_sha256: "cdc7023e6f2d4cc112de67cfeebf47b23d2914e96ca99cc6f1f8c4390d15a8e1"
    },
    "ex_dominates_exar" => %{
      fixture_sha256: "c17cded72bf2ad1924f0646d3b6225e95a724c825cc43225b39ec01151002a18"
    },
    "crop_corner_placement" => %{
      fixture_sha256: "780022203c06f158eb8545bd9690b121150b1dbb25519480b56f4f0b39fa40de"
    },
    "cover_gravity_south_offset_marker" => %{
      fixture_sha256: "892457cfed820ba8fc335c32155c450230fa641860f6b94e57075532be6697f1"
    },
    "grav_ce_rel_off" => %{
      fixture_sha256: "b33090cff7904ff433f17c5ebd0d56e57df96668995c2de4e1ca639f00d43e75"
    },
    "grav_so_off" => %{
      fixture_sha256: "580873e641a942c4b1fbdd4a61d5427075198e9fe7f1af8402ceb9c1ad4ce783"
    },
    "extend_gravity_north_small" => %{
      fixture_sha256: "cad8f380cd29378a0ff86ba270333033bc6cd4dbcdb3759ae88e2949b0c959f2"
    },
    "extend_offset_east_marker" => %{
      fixture_sha256: "99327146b129ba5b4bd2c80f1f5964d68e607ac87990b5f2cc5304ed4b6ee2b8"
    },
    "extend_padding_stack_small" => %{
      fixture_sha256: "d2802f1f15949d73b1ddf3b7ff0128def0382520875252af8b3e5955e78892a0"
    },
    "trim_equal_h_exif5" => %{
      fixture_sha256: "356a11d4845340173e3ec149c165e1cd276dc0047050d0c5970c4b2cb646a038"
    },
    "exif_5_cover_rot90" => %{
      fixture_sha256: "255202508ca2403b8307a2928b51178ced4c38a13745135760f75ac791005e50"
    },
    "cover_west_gravity_marker" => %{
      fixture_sha256: "cc951096a398c2ae0347478e4604d8d63e0b2b707c42880be21800597bf36dd5"
    },
    "exif_7_cover_rot90" => %{
      fixture_sha256: "f6ced049d65c6f9b957fd0d739135d7deda98def7e6f928d9d5e585ed560486f"
    },
    "exif_4_crop_no" => %{
      fixture_sha256: "6d320fe78bd2cd98e8de1dea37bfa0c947a11fa5a25b0e72b8008acd49c51303"
    },
    "rgba16_preserve_hdr" => %{
      fixture_sha256: "2eed28ab08e3dfb2fd4441fbe6570fa2b5c0cf94a3611a5ad547add2c0c043ee"
    },
    "exif_3_cover" => %{
      fixture_sha256: "bbe4adabd8293b548fa7933f110f6d65299af7b84d6ef21a5029b1e82d9ff8bd"
    },
    "exif_7_extend_so" => %{
      fixture_sha256: "209d4e4ea4fc451007ed1a3888db0a83336ecef84326f474f266b434619821e3"
    },
    "exif_crop_focal" => %{
      fixture_sha256: "6f7380739c9aa949e3102829cabe2ddaf9ca57ff6671abdcc83cbbd6ca43639d"
    },
    "exif_crop_north" => %{
      fixture_sha256: "1cfc70f3884009d60100aa6d83ae5cc5ddf101e03fb1b01964f59fa0a92a6080"
    },
    "crop_gravity_placement" => %{
      fixture_sha256: "65c19f17fcf0110fa45ef5e46a77e3ca9d90f1f4f017f229019d3b16aa089ff3"
    },
    "exif_5_cover" => %{
      fixture_sha256: "2c5fdb339ee14be1fcc30d098ca80dca9e30cf09f48b68a33c11ce4d3ad2271b"
    },
    "user_rot180_marker" => %{
      fixture_sha256: "25ec6ecdb9819a322dc873f4481293cdc9eff940c04e2fb39ef0983ed9961240"
    },
    "trim_equal_hv_border" => %{
      fixture_sha256: "e00a29a6c06e316258b52fb51795248503b7d2c25d48676bca3615b9d0e96bfc"
    },
    "cover_odd_gap_corner_marker" => %{
      fixture_sha256: "6ed5eef448f92392f943ee65bcae8f428828a7b4eaaa532fc0ae9d1ce2415f4a"
    },
    "rs_fill_zone" => %{
      fixture_sha256: "49067e71914e1ceb56b144d8eefe5c54c1caa2de724c1d1117d518715569c1e5"
    },
    "exif_5_crop_no" => %{
      fixture_sha256: "cb0ef932743dc2d6abe9688447ae8f2c795fae50225ff2a81779c0ccf52ab690"
    },
    "grav_sowe_off" => %{
      fixture_sha256: "5568cd750bfb92d57cad44503714f02f945047e2563ebc2885f13d43a6ed12e6"
    },
    "exif_5_cover_fl" => %{
      fixture_sha256: "7b7c895adfc90b4546f5dd82aeb22ab7b8a0eda59efa4c61718a58e9aaff0126"
    },
    "extend_small" => %{
      fixture_sha256: "c17cded72bf2ad1924f0646d3b6225e95a724c825cc43225b39ec01151002a18"
    },
    "auto_resize_square_target_marker" => %{
      fixture_sha256: "bd1ebd7079f7d41f861fa3249b43d1b290e30f913f14744d6b8c897d00b0c103"
    },
    "crop_inherit_grav_offset" => %{
      fixture_sha256: "c3753086394cdf7a5c01ae0dcc3c01c951b0246303a1252b5910418f30141868"
    },
    "cover_offset_dpr_marker" => %{
      fixture_sha256: "5eacf1059134d3a40971cee9b56b2af7e7d4635b646ecebe98e58feec9027293"
    },
    "scp0_colorspace_124" => %{
      fixture_sha256: "c636d669a31d09095e539ee312bd89744b4d6f88064dba9580fe559fb0e8cb4d"
    },
    "exif_7_cover_fl" => %{
      fixture_sha256: "2b1b736ed8a03f337ee9405951199fa5e011402e40cd9c48e712b80cc25c69ab"
    },
    "exif_4_cover" => %{
      fixture_sha256: "f6ced049d65c6f9b957fd0d739135d7deda98def7e6f928d9d5e585ed560486f"
    },
    "exif_182_padding_no_resize" => %{
      fixture_sha256: "7671a296cc624b566b3526fa041ecb9bbf63d32c4a8917487b687d7aec732623"
    },
    "flip_v_marker" => %{
      fixture_sha256: "d42e4551a3be362316d26269b302766a75a3ccdc3870bd18fd202ede1d841fd9"
    },
    "extend_ar_small" => %{
      fixture_sha256: "b228e4eb6c51b2ee76f132330567c629859803875ec544311bd070ae7bdb4b1d"
    },
    "crop_east_offset_placement" => %{
      fixture_sha256: "cdc7023e6f2d4cc112de67cfeebf47b23d2914e96ca99cc6f1f8c4390d15a8e1"
    },
    "extend_offset_clamp_dpr_small" => %{
      fixture_sha256: "563e2b027b051acda07cbfeca7577dfd3bda49ee6cea54a2cbe234b57ae75835"
    },
    "grav_so" => %{
      fixture_sha256: "e1d6133c192b8581eae0e87ccc2ec83c9a7a0e919c30f30b6ed330109e004b90"
    },
    "grav_noea" => %{
      fixture_sha256: "ac77f8ef309cb4aab23b0f2fdd708a0d24c3f905a41f1fb99df078ef33a2d2fc"
    },
    "extend_ar_dpr_marker" => %{
      fixture_sha256: "aa11c87e7f0ab3640e99e33fa8723fc0373a52dfb4fce1786e70ea5c1269db06"
    },
    "grav_ce" => %{
      fixture_sha256: "8c5f8a35d273d31a061054118d4149d61b5fda4100775333603c9bb867218127"
    },
    "extend_dpr_fractional_marker" => %{
      fixture_sha256: "aa11c87e7f0ab3640e99e33fa8723fc0373a52dfb4fce1786e70ea5c1269db06"
    },
    "exif_7_cover" => %{
      fixture_sha256: "122320325795a93e90121504d8115ce5d10c5cb838ad823278c78733316714db"
    },
    "grav_we_off" => %{
      fixture_sha256: "73e3f0b5fbe124a79e4dede376fe331ef2a69d1b3d1e25bb06cb4ad2eec0638a"
    },
    "trim_resize_high_freq" => %{
      fixture_sha256: "1470298dfbd3d677e9c6f4ad75f38445f48c5851f2e759dc3e63e1c257810d69"
    },
    "cover_corner_gravity_marker" => %{
      fixture_sha256: "fe01761f16eea85fdcebe34db835579bad6c1adc428914e1d2c5190c7df48d54"
    },
    "crop_resize_two_gravities_marker" => %{
      fixture_sha256: "03afc585b5e5abf85d5367a0c9a6ac907aa35b3adba4ee8f8417ceca7b566243"
    },
    "rot90_flip_h_marker" => %{
      fixture_sha256: "3602aa2bb77f1d211b4943e282539533bb9323e14ed91cfac98a88960d84221f"
    },
    "exif_7_crop_no" => %{
      fixture_sha256: "e9a1433b8c78bb2d0d6a66b0ac927cadaa3628c568dbe9c76ea80ff119337a13"
    },
    "alpha_extend_bg" => %{
      fixture_sha256: "cdcaf41f0c8f64c3f76aa258be5789dea1cd6f7843e95230e10fd7099ce29713"
    },
    "exif_182_auto_branch" => %{
      fixture_sha256: "20ad2e78dec48eda5c7b9e18e9154c6350891841c122b376c7dce2f593cb7c4e"
    },
    "rs_fit_zone" => %{
      fixture_sha256: "eb4dfa2bee8f658209f2786c5d3a4518f84173209b55864568f233fd09c4be31"
    },
    "rot90_crop_north_placement" => %{
      fixture_sha256: "8519282908a0245b01a1bc576c2dd6aff3636fd72e5d168f216722d73b9a3f49"
    },
    "trim_icc_p3" => %{
      fixture_sha256: "4af9c52b2a01bae8cc0ca491a68f1f8072f3a6c31ace8e7e5c30adfd02aa9a74"
    },
    "crop_focal_placement" => %{
      fixture_sha256: "e94d29d26fea3e9828f883d73b3a04b1cf311a831dcb89b108c2ff738c954628"
    },
    "rgb16_tonemap_8bit" => %{
      fixture_sha256: "c3b5c879c371810800afff4f44880a8c6d29e6a5f0bf1296343d0ba22aa0196f"
    },
    "resize_tail_enlarge_extend_small" => %{
      fixture_sha256: "8d7631377411352bb6dd7cde573eb082005f1a93567646ea22fa3dd38857f651"
    },
    "grav_no" => %{
      fixture_sha256: "f5aac4fb68af709ea600b4ee05ced38d54ae748daa89fcf851394501e6beea57"
    },
    "exif_cover_focal_transpose" => %{
      fixture_sha256: "fb59c994e0f6e4ee0e4fce41e3a7181c465b3a864a3999a2eb5bbb9a03c0a17f"
    },
    "crop_relative_dims_placement" => %{
      fixture_sha256: "74ec816c74c1305442de87b6240744ef92bf19447405184875f30cff0a481f1e"
    },
    "enlarge_off_dpr_comp_small" => %{
      fixture_sha256: "dd59be38f7dbc89f7cbb930d2b6f738ee418acea6469adb72943d72aabe1634e"
    },
    "fill_down_marker" => %{
      fixture_sha256: "2939a6d8a0de7382492f0f268b896e4663e75b63d5be6846b86248e9f8d6c8da"
    },
    "exif_8_extend_so" => %{
      fixture_sha256: "053a2a202bfa785721c8e9cd4fdb09b5a3d62934858c7d80fece6a94d9d82af5"
    },
    "crop_relative_dims_odd_tie" => %{
      fixture_sha256: "a8ebca7df8186de2e21d1a0ac5619c0a7821cdbd545004d12e605f81a23e1909"
    },
    "scp0_blur_icc_p3" => %{
      fixture_sha256: "277e3cc0a0fc915323978f2bb6d3680bab76b8fcc9abab29cb0fb6092374f6c3"
    },
    "cover_min_dims_marker" => %{
      fixture_sha256: "58eb1dd93b5541973c662cdbf3f7e3546ac7cc5fae0aa6f7f78116db1a643935"
    },
    "padding_dpr_border" => %{
      fixture_sha256: "423ee3f25796212d24fab9eef6ad27de8f67fb62d69eeae973b2f893b37c2b15"
    },
    "resizing_type_direct_marker" => %{
      fixture_sha256: "a2bb00551c4e82f9951c5437fbaee04b568c81fd916e3f84f5f326b173257e07"
    },
    "exif_8_cover" => %{
      fixture_sha256: "2b1b736ed8a03f337ee9405951199fa5e011402e40cd9c48e712b80cc25c69ab"
    },
    "pixelate_marker" => %{
      fixture_sha256: "522a35bf4f754db93a6d6816cf413c067a62cd11e2bee2fa4c0cb6c6de32f9e6"
    },
    "blur_zone" => %{
      fixture_sha256: "02e9f874b5b4bf5cf007a844040bc7e3806abdd55216d67e024b737a71c8ecd3"
    },
    "extend_corner_offset_small" => %{
      fixture_sha256: "d26cb97cf990f1a00ac95d0f40bf826f433cd7d344e5342a24b00ef77cdf601c"
    },
    "dpr_marker" => %{
      fixture_sha256: "e5fb54254c615ec898969e041fcb1e9e53fa3961045bd28ce846d899a520c0e1"
    },
    "exif_auto_square_marker" => %{
      fixture_sha256: "a8b69e3cb2d73be56760aae2df633a33fb650f06a4f54fd7258a4363743872b9"
    },
    "fill_down_target_gt_source_small" => %{
      fixture_sha256: "86c67d8c5bbdb74b0e939795f0d825795b4a0fdd685995405bf5f9ddf043f376"
    },
    "resize_width_only_marker" => %{
      fixture_sha256: "47851b26cfab3e08e0eb98a52fc3a08d9fe173b2da123889199a71d53a4a52cf"
    },
    "exif_182_auto_pad_dpr_cap" => %{
      fixture_sha256: "e713fdd73df5a83658c5d8a48217558753f647236f30d9a48828a3f5fd7bc48b"
    },
    "extend_gravity_small" => %{
      fixture_sha256: "6f88a30a85bafce0da26d6f78481e833d2f3fab467ca69029b3b7dd84cd424e9"
    },
    "exif_3_extend_so" => %{
      fixture_sha256: "2f0389acb56d7c26683ddd6e00f0a240a45d97a2adb465d6773e927d123b0ed8"
    },
    "size_marker" => %{
      fixture_sha256: "a2bb00551c4e82f9951c5437fbaee04b568c81fd916e3f84f5f326b173257e07"
    },
    "sharpen_zone" => %{
      fixture_sha256: "ad6fb7b30b6afe83d7bd7c808d010cdd5f06feef5088b54a8ea6b6c8adaae7ee"
    },
    "alpha_resize" => %{
      fixture_sha256: "4423b7a96fff78ba10be919543ea7d515067da45c83fdaa7c59add65b47357f6"
    },
    "exif_2_cover" => %{
      fixture_sha256: "255202508ca2403b8307a2928b51178ced4c38a13745135760f75ac791005e50"
    },
    "grav_sowe" => %{
      fixture_sha256: "8adfabe6abf936711caa1c5346faf10d4c89eedfab9f24fce7b517304f9be38d"
    },
    "exif_user_flip_h" => %{
      fixture_sha256: "356a11d4845340173e3ec149c165e1cd276dc0047050d0c5970c4b2cb646a038"
    },
    "exif_8_crop_no" => %{
      fixture_sha256: "99449d7cdf5c29395b041ad60fbcb92aa5eebe7deddd3f0bbf32da59fe2f324d"
    },
    "lossy_webp" => %{width: 240, height: 180, content_type: "image/webp"},
    "padding_border" => %{
      fixture_sha256: "1af6ead813738e1c08a94d74bb5901bbe999da983a6e9b3a7f84d082ac1ddf31"
    },
    "zoom_offset_no_scale" => %{
      fixture_sha256: "35334171012f49dbaf4ca819b88ab02b17529de5aeb59f4b90eb70d4babf814f"
    },
    "trim_border_equal" => %{
      fixture_sha256: "f25e7af1bf08e3df79b6ace82515d7276dc92575f96006f24d37b3b72bf48336"
    },
    "gravity_offset_marker" => %{
      fixture_sha256: "a6cb42f915db8661374325d8e85931017c9d881ba5617331ec7737108a13e44c"
    },
    "lossy_jpeg_q40" => %{width: 240, height: 180, content_type: "image/jpeg"},
    "grav_nowe_off" => %{
      fixture_sha256: "0b228be1541dc6b840d455aa2669c79de9472d3a7e1e0fbdc059a01ca50de663"
    },
    "grav_no_off" => %{
      fixture_sha256: "c3753086394cdf7a5c01ae0dcc3c01c951b0246303a1252b5910418f30141868"
    },
    "exif_2_extend_so" => %{
      fixture_sha256: "ef29ecd2a6a9aca14bd72650ede278c87f530c6b97cdef6b6935ab52f5d70369"
    },
    "effects_chain_order_high_freq" => %{
      fixture_sha256: "6dabd60fea767033d02075a8815bdabf88f716dbbe1cb3630a108c654e14a203"
    },
    "cover_corner_offset_marker" => %{
      fixture_sha256: "ccf45e04748c551df84836fca2712b604275bbd5c50fda3d76848d18d31aa1d4"
    },
    "exif_182_pixelate" => %{
      fixture_sha256: "7577068b53ddba0d274e4ee20a22092dcf39e2e233edd781de3945f789ec0102"
    },
    "zoom_padding_no_scale" => %{
      fixture_sha256: "91b109d0aedc3142ab9cd8bb8c6fc595b099c59b629654799c66d64bba40575d"
    },
    "crop_focal_edge_placement" => %{
      fixture_sha256: "df84ba1da81c487987375ed885001ffc724a314e887071bef3ba2ff016bb588b"
    },
    "cmyk_import" => %{
      fixture_sha256: "3edbf150cac23cb36ddcc60e59b6bc2f8657abed560cbebd3c76dec8d0138799"
    },
    "cover_odd_gap_corner_dpr_marker" => %{
      fixture_sha256: "1a36b442593a4c27919fe48d5192a60a26a2a9f08e5cf40f9cabd7d8039230ba"
    },
    "flip_h_marker" => %{
      fixture_sha256: "97a92326a2223a93ba24e7bc7c793c000e848a50afaa1ece4c392c97d80c01f2"
    },
    "crop_smart_marker" => %{
      fixture_sha256: "89c3c63fc4b6c8580ec5e62a72a27fec124fa0b9cad63a7a794a6cf44638bf25"
    },
    "extend_offset_dpr_marker" => %{
      fixture_sha256: "68adbb1be71963d2036f2e0535843bd9a0bd8fa3721ee4744ed627266a8b6f91"
    },
    "zoom_cover_resultcrop_marker" => %{
      fixture_sha256: "786b2dbc90f92ae5cbb6d1291af3cfdda657e7f0b38f17d4e4472587ca7eb751"
    },
    "cover_focal_marker" => %{
      fixture_sha256: "3571ad4e89b9d6ad964d5dffd1fe6e4c763a50d7b7a2cb286c73b6d44d49dea3"
    },
    "grav_we" => %{
      fixture_sha256: "19b03f87ecea0020a6d281a699b174c9a963312b7de138f31477afd60508675c"
    },
    "rgb16_preserve_hdr" => %{
      fixture_sha256: "e21e3b68d09819003d2fa0cbe46e70c665fb53ba375cd4d21558eb11b1177110"
    },
    "exif_user_rot90" => %{
      fixture_sha256: "affcf95a6c6eea6fd2f79027f8490292617369a9cfa81b24d47286a0cafc86ef"
    },
    "grav_nowe" => %{
      fixture_sha256: "0ab4eb180619392ae26411bc8850d9d45d8daa7ca8e659a1d6485378c8750386"
    },
    "rs_fill_webp_residual" => %{
      fixture_sha256: "9a384d245050b259bcd38efdf8c480caaf570bdc112149c5cd4917b432916332"
    },
    "rgba16_tonemap_8bit" => %{
      fixture_sha256: "2c508acf5cbe33eb4f2519cb72efbc4a04c5c6786f7c0e1791ede65a9bcc6b69"
    },
    "force_resize_marker" => %{
      fixture_sha256: "b9a1442e44341fdc7023896be69f33159e0ed1c8b7e0e9647d4b27c9ef83cc02"
    },
    "fill_down_corner_gravity_marker" => %{
      fixture_sha256: "81e505a01f3d56b81a62745684eb071abe8dac60c6ca7772e687fb0b983e75f6"
    },
    "auto_resize_marker" => %{
      fixture_sha256: "c55cd6309fa68b2e9244f3dbd9e0c18d62ef82f8392b42a968acdf3d0ff18b61"
    },
    "grav_ea" => %{
      fixture_sha256: "a48b1dcdf9b4e9101eef6043c1c1a0e3661fe3dde1f00ff8a9ba5508eede530f"
    },
    "crop_full_axis_placement" => %{
      fixture_sha256: "d2727e0883ca0e97c2f49ae5a67a139d49f97b0ac88a09bdcc466dc6bd5405cf"
    },
    "enlarge_small" => %{
      fixture_sha256: "566e927840c7a479afe63b1042d32bdd2df82edce0230e3a3c573a42e00c65ce"
    },
    "width_only_marker" => %{
      fixture_sha256: "47851b26cfab3e08e0eb98a52fc3a08d9fe173b2da123889199a71d53a4a52cf"
    },
    "rotate_exif" => %{
      fixture_sha256: "79d98874795f31d33cb9c4739f7eb69f1b83c2e3b1096858f9ca126232db9322"
    },
    "exif_4_extend_so" => %{
      fixture_sha256: "f0faef7ede4bbe5e4f7593bf8127b2cc336a4df88752c4f50efc77826dfccf19"
    },
    "enlarge_off_dpr_extend_small" => %{
      fixture_sha256: "910aa810c9314da456f1a9f13506e2b49561180cf859741333011706d9726a2e"
    },
    "grav_ce_off" => %{
      fixture_sha256: "9fa1b4c9fe2661ae107ed97911b02365ab3bdb4b27a63e098b8ab4be16435f5a"
    },
    "trim_exif_cover_crop" => %{
      fixture_sha256: "999a7afcfdf58f5dc19ac0b48cc2ab55d364790074b724456842d9bb67c4a74d"
    },
    "background_alpha" => %{
      fixture_sha256: "cdcaf41f0c8f64c3f76aa258be5789dea1cd6f7843e95230e10fd7099ce29713"
    },
    "lossy_avif" => %{width: 240, height: 180, content_type: "image/avif"},
    "cover_rel_offset_dpr_marker" => %{
      fixture_sha256: "781e18414afe7ea6005a01834ad6847d447e304ff94cb9096663637f750fa180"
    },
    "exif_3_crop_no" => %{
      fixture_sha256: "72c0684d1cd41a0069acac6f408ec1a87fe6a1041ef7c2dac33c36776d439f0b"
    }
  }
}
