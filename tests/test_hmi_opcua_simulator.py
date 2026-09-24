from pathlib import Path

import pytest

from asyncua import Client, ua
from asyncua.ua.uaerrors import UaStatusCodeError
from hmi_opcua_simulator import (
    READ_TAGS_FILE,
    WRITE_TAGS_FILE,
    configure_server,
    load_tags,
)


def test_load_tags_preserves_node_ids_types_and_access():
    read_tags = load_tags(READ_TAGS_FILE, writable=False)
    write_tags = load_tags(WRITE_TAGS_FILE, writable=True)

    assert len(read_tags) == 192
    assert len(write_tags) == 127
    assert read_tags[6].node_id == '"HMI_Out"."Cell"."AllowTray_1Removed"'
    assert read_tags[6].value is False
    assert read_tags[41].value == [0] * 101
    assert write_tags[39].variant_type == ua.VariantType.String
    assert all(not tag.writable for tag in read_tags)
    assert all(tag.writable for tag in write_tags)


@pytest.mark.asyncio
async def test_server_allows_only_configured_writes(unused_tcp_port: int):
    endpoint = f"opc.tcp://127.0.0.1:{unused_tcp_port}/hmi/server/"
    server, nodes = await configure_server(endpoint)

    assert len(nodes) == 319
    async with server, Client(endpoint) as client:
        writable = client.get_node('ns=3;s="HMI_IN"."Header"."StartReq"')
        await writable.write_value(True, ua.VariantType.Boolean)
        assert await writable.read_value() is True

        array_element = client.get_node(
            'ns=3;s="HMI_IN"."Recipe_Sel"."RCP_Data"."Mod1"."PickOrder"[0]'
        )
        await array_element.write_value(12, ua.VariantType.Int16)
        assert await array_element.read_value() == 12

        read_only = client.get_node('ns=3;s="HMI_Out"."Header"."CellStatus"')
        assert await read_only.read_value() == 0
        with pytest.raises(UaStatusCodeError):
            await read_only.write_value(1, ua.VariantType.Int16)


def test_malformed_tag_file_is_rejected(tmp_path: Path):
    tag_file = tmp_path / "tags"
    tag_file.write_text("not\tenough\tcolumns\n", encoding="utf-8")

    with pytest.raises(ValueError, match="expected at least 7"):
        load_tags(tag_file, writable=False)
