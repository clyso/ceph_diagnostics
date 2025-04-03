cds pg scrub-stats
```
total number of pgs: 4449
total scrub duration: 259619 sec
average scrub duration: 58 sec
total number of objects: 673149263
average number of objects per pg: 151303
total size: 2220003750197429 bytes
average pg size: 498989379680 bytes
per pool scrub duration:
  24: 259474 sec (4096 pgs, 63 sec/pg, 541991969822 bytes/pg, 164215 obj/pg, 49.33 sec std_dev)
  25: 96 sec (128 pgs, 0 sec/pg, 0 bytes/pg, 2341 obj/pg, 0.72 sec std_dev)
  26: 38 sec (32 pgs, 1 sec/pg, 134571 bytes/pg, 5850 obj/pg, 0.37 sec std_dev)
  21: 0 sec (32 pgs, 0 sec/pg, 0 bytes/pg, 0 obj/pg, 0.00 sec std_dev)
  15: 3 sec (32 pgs, 0 sec/pg, 128357019 bytes/pg, 38 obj/pg, 0.26 sec std_dev)
  14: 0 sec (32 pgs, 0 sec/pg, 128 bytes/pg, 0 obj/pg, 0.00 sec std_dev)
  16: 0 sec (32 pgs, 0 sec/pg, 0 bytes/pg, 0 obj/pg, 0.01 sec std_dev)
  17: 6 sec (32 pgs, 0 sec/pg, 309681 bytes/pg, 1083 obj/pg, 0.07 sec std_dev)
  20: 0 sec (32 pgs, 0 sec/pg, 0 bytes/pg, 2 obj/pg, 0.00 sec std_dev)
  7: 0 sec (1 pgs, 0 sec/pg, 520160352 bytes/pg, 125 obj/pg, 0.00 sec std_dev)
```


cds osd sum
```
OSD DEV TYPES: {'hdd': 0, 'hybrid': 0, 'ssd': 50}
OSD HOSTS:
 ceph-0001 (10): [0, 179, 419, 424, 429, 434, 439, 444, 449, 454]
 ceph-0002 (10): [178, 418, 423, 428, 432, 437, 442, 447, 453, 458]
 ceph-0003 (10): [177, 417, 422, 427, 433, 438, 443, 448, 452, 457]
 ceph-0004 (10): [176, 416, 421, 426, 431, 436, 441, 445, 450, 455]
 ceph-0005 (10): [175, 378, 420, 425, 430, 435, 440, 446, 451, 456]
```

cds rgw top - outputs bucket metrics (can sort by metric)
```
Bucket Name                                            Num Objects     Shards      Size (TiB)      Objects/Shard
----------------------------------------------------------------------------------------------------------------
bucket-1                                                   62,214         17           49.99           3,659.65
bucket-2                                                  448,326         37           29.50          12,116.92
bucket-3                                                      422         17           23.22              24.82
bucket-4                                                  202,075         37           22.37           5,461.49
bucket-5                                                8,016,419      10009           21.96             800.92
bucket-6                                                  305,441         37           20.93           8,255.16
bucket-7                                                   91,222         17           19.20           5,366.00
bucket-8                                                  228,727         17           18.92          13,454.53
bucket-9                                                  267,896         17           16.33          15,758.59
bucket-10                                                  11,549         17           15.07             679.35
bucket-11                                                 269,496         17           14.10          15,852.71
bucket-12                                                 198,716         17           13.89          11,689.18
bucket-13                                                 197,877         17           13.42          11,639.82
bucket-14                                                 198,345         17           13.37          11,667.35
bucket-15                                                 203,168         17           13.14          11,951.06
bucket-16                                                   6,245         17           12.61             367.35
bucket-17                                                  16,442         17           12.52             967.18
bucket-18                                                  15,526         17            9.93             913.29
bucket-19                                                 478,856         37            7.98          12,942.05
bucket-20                                                  15,939         17            5.99             937.59
```
