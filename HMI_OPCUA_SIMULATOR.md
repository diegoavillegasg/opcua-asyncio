# HMI OPC UA simulator

The simulator loads all tags from:

- `HMI_TAGS_TO_READ_OPC_UA_REAL_DATA_STRUCTURE` as read-only nodes
- `HMI_TAGS_TO_WRITE_OPC_UA_REAL_DATA_STRUCTURE` as readable and writable nodes

It preserves the exported NodeIds exactly, including namespace 3. Start it from
the repository root with:

```bash
.venv/bin/python hmi_opcua_simulator.py
```

The default endpoint is `opc.tcp://0.0.0.0:4840/hmi/server/`. Connect locally
with `opc.tcp://localhost:4840/hmi/server/`.

Options can override the endpoint and input files:

```bash
.venv/bin/python hmi_opcua_simulator.py \
  --endpoint opc.tcp://0.0.0.0:4841/hmi/server/ \
  --read-tags HMI_TAGS_TO_READ_OPC_UA_REAL_DATA_STRUCTURE \
  --write-tags HMI_TAGS_TO_WRITE_OPC_UA_REAL_DATA_STRUCTURE
```

For example, the following nodes are exposed:

- Read-only: `ns=3;s="HMI_Out"."Header"."CellStatus"`
- Writable: `ns=3;s="HMI_IN"."Header"."StartReq"`

Press `Ctrl+C` to stop the server.

## Kepware Server alternative

For an independent industrial OPC server instead of the Python simulator, see
[`KEPWARE_SERVER_SETUP.md`](KEPWARE_SERVER_SETUP.md). It documents the local
KEPServerEX installation and the parameterized import script at
`tools/Configure-KepwareSimulator.ps1`.
