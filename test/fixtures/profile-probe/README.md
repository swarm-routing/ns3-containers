# profile-probe

One deliberate behaviour per `--mode` (`assert`, `log`, `uaf`, `leak`,
`overflow`), built from the image's ns-3 tree by `test/profile.sh`
(ns3-containers#41) to prove each build profile does what its name says:
asserts and `NS_LOG` on in `default`/`debug`/`sanitized` and compiled out in
`optimized`, and ASan, LSan and UBSan each reporting their planted bug in
`sanitized`. Written against public ns-3 APIs only.
