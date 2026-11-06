step5_predict: TG68_PREDICT (next-address prediction), full config, seed 29
built with yowasp-yosys 0.70.0.0.post1259, yowasp-nextpnr-ecp5 0.11.1.0.post826, oss-cad-suite ecppack
  python3 scripts/build.py full --predict --seed 29 --seeds 1
plain = as built; fast = ecppack --compress --freq 38.8 from the same routed config
NOT TESTED IN AN AMIGA. Fall back to step4_dcache if anything misbehaves.
