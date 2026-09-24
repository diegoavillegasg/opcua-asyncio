"""OPC UA simulator built from the exported HMI tag lists."""

import argparse
import asyncio
import logging
import re
from dataclasses import dataclass
from pathlib import Path

from asyncua import Server, ua


LOGGER = logging.getLogger(__name__)
BASE_DIR = Path(__file__).resolve().parent
READ_TAGS_FILE = BASE_DIR / "HMI_TAGS_TO_READ_OPC_UA_REAL_DATA_STRUCTURE"
WRITE_TAGS_FILE = BASE_DIR / "HMI_TAGS_TO_WRITE_OPC_UA_REAL_DATA_STRUCTURE"
NAMESPACE_URI = "PLC:Factory"


@dataclass(frozen=True)
class Tag:
    node_id: str
    browse_name: str
    value: object
    variant_type: ua.VariantType
    writable: bool


TYPE_MAP = {
    "Boolean": ua.VariantType.Boolean,
    "Byte": ua.VariantType.Byte,
    "Double": ua.VariantType.Double,
    "Float": ua.VariantType.Float,
    "Int16": ua.VariantType.Int16,
    "Int32": ua.VariantType.Int32,
    "Int64": ua.VariantType.Int64,
    "SByte": ua.VariantType.SByte,
    "String": ua.VariantType.String,
    "UInt16": ua.VariantType.UInt16,
    "UInt32": ua.VariantType.UInt32,
    "UInt64": ua.VariantType.UInt64,
}


def _parse_value(raw_value: str, data_type: str) -> tuple[object, ua.VariantType]:
    variant_type = TYPE_MAP.get(data_type, ua.VariantType.String)
    if data_type == "Boolean":
        return raw_value.strip().lower() == "true", variant_type
    if data_type in {"Byte", "Int16", "Int32", "Int64", "SByte", "UInt16", "UInt32", "UInt64"}:
        if raw_value.startswith("{") and raw_value.endswith("}"):
            values = raw_value[1:-1].split(",")
            return [int(value.strip()) for value in values if value.strip()], variant_type
        return int(raw_value or 0), variant_type
    if data_type in {"Double", "Float"}:
        return float(raw_value or 0), variant_type
    # Custom PLC structures have no portable scalar value in the export. A
    # string placeholder keeps the tag readable while its members are browsable.
    return raw_value, variant_type


def load_tags(path: Path, *, writable: bool) -> list[Tag]:
    tags = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        columns = line.split("\t")
        if len(columns) < 7:
            raise ValueError(f"{path}:{line_number}: expected at least 7 tab-separated columns")
        exported_node_id = columns[2]
        if not exported_node_id.startswith("ns=3;s="):
            raise ValueError(f"{path}:{line_number}: unsupported NodeId {exported_node_id!r}")
        value, variant_type = _parse_value(columns[5], columns[6])
        tags.append(Tag(exported_node_id[7:], columns[4], value, variant_type, writable))
    return tags


async def _register_namespace_three(server: Server) -> int:
    namespace_index = await server.register_namespace(f"{NAMESPACE_URI}:reserved")
    if namespace_index != 2:
        raise RuntimeError(f"expected the reserved namespace at index 2, got {namespace_index}")
    namespace_index = await server.register_namespace(NAMESPACE_URI)
    if namespace_index != 3:
        raise RuntimeError(f"cannot expose exported NodeIds in namespace 3 (allocated {namespace_index})")
    return namespace_index


async def configure_server(
    endpoint: str,
    read_tags_file: Path = READ_TAGS_FILE,
    write_tags_file: Path = WRITE_TAGS_FILE,
) -> tuple[Server, dict[str, object]]:
    server = Server()
    await server.init()
    server.set_endpoint(endpoint)
    server.set_server_name("DIEGO_SIM_PLC")
    namespace_index = await _register_namespace_three(server)

    read_tags = load_tags(read_tags_file, writable=False)
    write_tags = load_tags(write_tags_file, writable=True)
    all_tags = read_tags + write_tags
    nodes: dict[str, object] = {}

    roots = {}
    for root_name in ("HMI_Out", "HMI_IN"):
        identifier = f'"{root_name}"'
        roots[root_name] = await server.nodes.objects.add_object(
            ua.NodeId(identifier, namespace_index), ua.QualifiedName(root_name, namespace_index)
        )

    for tag in all_tags:
        root_name = "HMI_IN" if tag.node_id.startswith('"HMI_IN"') else "HMI_Out"
        if re.search(r"\[\d+\]$", tag.node_id):
            parent_identifier = re.sub(r"\[\d+\]$", "", tag.node_id)
        else:
            parent_identifier = tag.node_id.rsplit(".", 1)[0] if "." in tag.node_id else f'"{root_name}"'
        parent = nodes.get(parent_identifier, roots[root_name])
        node = await parent.add_variable(
            ua.NodeId(tag.node_id, namespace_index),
            ua.QualifiedName(tag.browse_name, namespace_index),
            tag.value,
            tag.variant_type,
        )
        if tag.writable:
            await node.set_writable()
        nodes[tag.node_id] = node

    LOGGER.info(
        "Loaded %d read-only tags and %d writable tags in namespace %d",
        len(read_tags),
        len(write_tags),
        namespace_index,
    )
    return server, nodes


async def run(args: argparse.Namespace) -> None:
    server, _ = await configure_server(args.endpoint, args.read_tags, args.write_tags)
    LOGGER.info("Listening at %s", args.endpoint)
    async with server:
        await asyncio.Event().wait()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default="opc.tcp://localhost:4840/")
    parser.add_argument("--read-tags", type=Path, default=READ_TAGS_FILE)
    parser.add_argument("--write-tags", type=Path, default=WRITE_TAGS_FILE)
    parser.add_argument("--log-level", default="INFO", choices=("DEBUG", "INFO", "WARNING", "ERROR"))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=args.log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        LOGGER.info("Server stopped")


if __name__ == "__main__":
    main()
