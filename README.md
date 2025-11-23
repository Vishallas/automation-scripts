# Harbor migration


```
./harbor-migration.sh \
    --migrate-from harbor-reports/harbor_artifacts_internal.csv \
    --harbor-user admin --harbor-pass Admin@dbops2021 \
    --ecr 950322363503.dkr.ecr.ap-south-1.amazonaws.com/mydbops/internal
