%{
  sources: %{
    "alpha.png" => "7ef18f9ce1e08b6752fa8e55caf0819882d3779b997b65ec7a6c0c45e3a75fee",
    "alpha_border.png" => "539bb44e3d5279a6be9cbc29f46a3e7554285fbacf74433d146bb0df2233dacf",
    "exif_6.jpg" => "ffc9f345632012165b7c80950b5d97999c370cc8f434995e52f58099fc675905",
    "exif_placement_6.jpg" => "647850a6d806cc8141574273bf8b4cf7cc76548331af2f00777b838dcdbb9d9f",
    "gray.png" => "5dbbff7926a2d0a99ad8f0519e311d79f9cd81428c804c6b6a9307780ff6293d",
    "high_freq.jpg" => "54ded6c57ec02c685e275276b54947f8c9345015342fc8a2acc9d8e54e4a7d43",
    "icc_p3.png" => "80ce9bc055c01a12a9d8bf3db1693a1b46995f66bfdb796503636122de264869",
    "marker.png" => "cbb47b49a36fc7a8b37233c862e1d4b88174ec6bf81876223779b4ce3c52120d",
    "palette.png" => "a963243e4caa27df9474da13a271ebd98a1313f07c5059045eeb264fb7192735",
    "placement.png" => "eb3de4dce6337ed2bd531b35187bcda3265542dc5b661152631839616eca7d09",
    "rgb16.png" => "e0601a09f13020b00dd88e45794dd7fd59368239607c482609f027ee423d8119",
    "small.png" => "517719b9e7ad77f867266b8c4e135d383cdc94c3bf14f7bc26c2060a98ae870a",
    "strip.png" => "1408259edc2de06db7e79afa0854dd0134a010e4e99b57024a35b5dd61a0779e"
  },
  cases: %{
    "rotate_30_alpha" => %{
      fixture_sha256: "673911a16af62b71509f2b4caa32826881c8c87e4dc1ec57fdc647576bbce1d3"
    },
    "gray" => %{
      fixture_sha256: "20dae2f98ed81b9eb01d2d54f5faaf71ab6a00d65c2a761c671d87ef878d7d06"
    },
    "region" => %{
      fixture_sha256: "da3144646173bcf77e937a6cff9f578535828ddf972e543a9a5ed1c5728954e1"
    },
    "p3_preserve_bg_extend" => %{
      fixture_sha256: "b8861d98693d923c45d74c83c2b2fc3f57bd54141e85458667db0ff5811dcb72"
    },
    "crop_ratio_enlarge" => %{
      fixture_sha256: "6cff58284e100f55594e8ddf4cb785b678213ba74107da2170230bd552593b32"
    },
    "jpeg_progressive" => %{
      fixture_sha256: "fa44d93a8f7d3246125dd218640b3ce4e1583615ea593ca234d93a8359a5f4f7"
    },
    "bitonal" => %{
      fixture_sha256: "30b076f6d0b81e542c20e0ed44d4161170cf289dcbb491058e96069fccb33d65"
    },
    "exif_pct_crop_centered" => %{
      fixture_sha256: "0aa5d6a8251c5026e1cb972ae5b1d941c9b0999787807bdde334c28288ae6f05"
    },
    "progressive_blur" => %{
      fixture_sha256: "9f24ceb318c2c6c9b1b9bbf5cabde04c469bfede856627d1ff47f0312de2891c"
    },
    "jpeg_alpha_flatten" => %{
      fixture_sha256: "20e01ef221ecd7750d4c584a95e33676290139527eda19ef22296f006f556106"
    },
    "gray_extend_bg_red" => %{
      fixture_sha256: "9c6e794fd1fb4b44faf1c8b3a15371a307bfe3872ebe8ede50e4b6ad5b6952c9"
    },
    "rgb16_colorize" => %{
      fixture_sha256: "8fd567bd67bdd6554ab561a67db707d56ad40970406d5a90ebedee296767fabe"
    },
    "rgb16_gray" => %{
      fixture_sha256: "1e46e3cf88517f390ad2a999c630f864e52bc4620677f041d1b390be4db61c1b"
    },
    "crop_ratio" => %{
      fixture_sha256: "a8da22141616406f9743c9035ff9a0db50ad26d1fc35afabb7e236e4cbcb14de"
    },
    "cover_min_dims_above_box" => %{
      fixture_sha256: "da900b294d6f5785142048d1739a84eca0ad3f0140b6a3b2575ac0f2bdf22386"
    },
    "group_dpr_reset" => %{
      fixture_sha256: "8f867a68d45413bbefff692a88f2f4e96b5a13cc9f2aaf62bd5e6ac6222bcc6b"
    },
    "group_chain" => %{
      fixture_sha256: "0e2e16e703d6ec3bb87533466eecc8db420d9fe4eb7a2f2e2c1cc21ff55e77c6"
    },
    "gray_colorize" => %{
      fixture_sha256: "6618a47568cf6a839dae07e668d994302b5a9b0864f62165de908d99e623f52a"
    },
    "wm_tile_gap" => %{
      fixture_sha256: "244cedd9cedafdcc9dc525186ee8a79aa045ee4ce741d69dd52b1b7662891bdd"
    },
    "pad_dpr_no_resize" => %{
      fixture_sha256: "8699f820dc43e56f4dd289fef288967c4d0de43df1f570fc68038c7d427d6d28"
    },
    "trim_auto_display_corner" => %{
      fixture_sha256: "09829c2b27a4d848218b3b5e076a5d0bf3dd93ca5a39a570fba75a6f77ca51ce"
    },
    "strip_cover_small" => %{
      fixture_sha256: "cbfa976d7780730833dcf7665d01fb3092838946b227be6bf929102e197a6cfb"
    },
    "monochrome" => %{
      fixture_sha256: "58ab450b3ecbb5d876d526ca1bd6415fecc410142547206456b53a12855448f1"
    },
    "colorize" => %{
      fixture_sha256: "191eab1807db0d29a31d1c24c17a9e6e1623ed0cb54d7e08272f01fd4a3bdd5a"
    },
    "webp_lossless" => %{
      fixture_sha256: "f04826ed66f024bf4dbe17fb3329a41fdb9b9cd9da9ec04ab904dc0d2720f895"
    },
    "min_w_beyond_box" => %{
      fixture_sha256: "4fe4c30929d37f0c222f4092a0fa39981dfb5ae883ed8f9b7fafcde10ebe382d"
    },
    "png_palette" => %{
      fixture_sha256: "c7b63c4cd48c45021bbc9d44ba0362daf45d60aedd7df8ed56d2a7c31e21bdeb"
    },
    "gray_pad_bg_neutral" => %{
      fixture_sha256: "c4c73db1683d1e8cd943e7e876be67e775b1755468d4bc4b6caff3be5b9313d1"
    },
    "gradient_down" => %{
      fixture_sha256: "ab0989d5408201f78e51b645d568aa38e3e3b57ed6c4718c64073946d8044759"
    },
    "saturation" => %{
      fixture_sha256: "d5a3623bb38c2a116ca70a340269872e28e392861f703487bb118289050d9f6c"
    },
    "avif_q60" => %{
      fixture_sha256: "12173836d3d8e73419cc3fa99f9b4d8393ff0f92da5d37373baf17cedf0e4c79"
    },
    "rgb16_gradient" => %{
      fixture_sha256: "9984d829f672e6d36510ecee62970d992197698315aee05f55c72ee5d9fd040e"
    },
    "rotate_crop_centered" => %{
      fixture_sha256: "cfc45e3ede2a00e1290211846b5c498cddcecb0743ef572b441162855a7f1217"
    },
    "p3_preserve_fit" => %{
      fixture_sha256: "366915b7469a34fb326822789dff872a6460503ba224984f92cfcf64a0f981ce"
    },
    "exif_smart_crop" => %{
      fixture_sha256: "76d53c2358badcd5dbe2eec4686dbd82ac6b82a540ccced20d20cc05feeb8177"
    },
    "webp_q80" => %{
      fixture_sha256: "fefe5f26b249be17d200d097b95dbb80c2883503b5543b57a575cb8bdfb69cb9"
    },
    "p3_strip_fit" => %{
      fixture_sha256: "82bcf436bfa0a3b6d45a2b5a24d5437a67e12a7d7d9a3f1643856cd36db2c7da"
    },
    "wm_opacity_pct_offset" => %{
      fixture_sha256: "65db35835941cef1ce22ecfb9d1f15de2d88911543f6a0a39579674304334e04"
    },
    "duotone" => %{
      fixture_sha256: "695b3f31bb91b304f421a3038c10871fc26f3417b60c9c2a4ba4be5454f542c1"
    },
    "colorize_keep_alpha" => %{
      fixture_sha256: "2c83a0242c184cbf1a2ca1eae8c426eb7784c3a74ad0e70a917235297d20b39e"
    },
    "rotate_45_bg" => %{
      fixture_sha256: "b347d8785378af45f658eaeec8d7c2241d32d29c5d857ce2d576098da237cadd"
    },
    "gray_watermark_colour" => %{
      fixture_sha256: "b48d4b9bbd328d6e058b4a97e13e60ed2236845aa7fe14e4089faee0089c5cc2"
    },
    "profile_display_p3" => %{
      fixture_sha256: "6e54c6ead69fe20396fb5449c5a4c346780533c5822ddcebd67297552246350f"
    },
    "wm_natural_dpr" => %{
      fixture_sha256: "29f00ddf2c83482c972d9e766e420d453fbfa371f139d46055938a247c601073"
    },
    "rotate_30" => %{
      fixture_sha256: "f90020155b8b3d2459e3281a868a511489c477a44086f7328c302726024118cf"
    },
    "brightness" => %{
      fixture_sha256: "c1f4610564678577174d02dcad18866412f92549c25c3531edf3f657da17f3b7"
    },
    "contrast" => %{
      fixture_sha256: "bfb07655927b5c1ea0923e64847764999ac14214b960b890146a4630d4bdd518"
    },
    "gradient_right" => %{
      fixture_sha256: "8eceb2686a8ea96ae7fd80e51a2d530736c2d2f4974a14e57ebc8266ede96a93"
    },
    "hdr_preserve_rgb16" => %{
      fixture_sha256: "b597348cd80273a9fc1e5f5186e21add322f7ff8fb5c3674918601691573a3d9"
    },
    "profile_adobe_rgb" => %{
      fixture_sha256: "58a5f8b758dcf7e3502d879d4306bc4b519011b1da4d27d13a243b700f8cc7df"
    },
    "p3_strip_bg_extend" => %{
      fixture_sha256: "e08986f6ac9c328aae4c2e6b6d0dafa99eaed8f804b01fcc7e75a806f1e310a0"
    },
    "jpeg_q80" => %{
      fixture_sha256: "d8abe0b55b7f9dc78377d899c06336ec8aba60ed717a55bdc7a9461e991bb737"
    },
    "p3_preserve_blur" => %{
      fixture_sha256: "2c889155cbbd47adbf184896ed9c8c1fe2c40fb5bb1c0b53db5f954ea7d07856"
    },
    "rgb16_duotone" => %{
      fixture_sha256: "98e5233ede9bb4521187492dfe78c695235774812ba23d7a88b5f399960a4b34"
    }
  },
  libvips: "8.18.7"
}
