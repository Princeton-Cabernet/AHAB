from dataclasses import dataclass
from typing import Tuple, Optional

FlowId = Tuple[int, ...]

LPF_DECAY = 16
LPF_SCALE = 0


@dataclass
class Packet:
    flow_id: FlowId
    timestamp: int
    size: int
    flow_rate: Optional[int] = None


SEED = 0x12345678


def proportional_drop_probability(flow_rate: int, enforced_limit: int) -> float:
    """ Return a drop probability proportional to how far the flow rate has exceeded the limit.
        If the limit is not exceeded, returns 0.
    """
    if flow_rate < enforced_limit:
        return 0.0
    return 1.0 - (enforced_limit / flow_rate)


def bytes_accepted(flow_rate: int, enforced_limit: int, packet_size: int) -> int:
    """
    How many bytes of a packet would be accepted in expectation by a policer.
    :param flow_rate: the flow rate of the packet's flow
    :param enforced_limit: the limited enforced upon the flow
    :param packet_size: the size of the packet
    :return: Bytes accepted in expectation
    """
    if enforced_limit > flow_rate:
        return packet_size
    return int((packet_size * enforced_limit) / flow_rate)


def bytes_rejected(flow_rate: int, enforced_limit: int, packet_size: int) -> int:
    """
    How many bytes of a packet would be rejected in expectation by a policer.
    :param flow_rate: the flow rate of the packet's flow
    :param enforced_limit: the limited enforced upon the flow
    :param packet_size: the size of the packet
    :return: Bytes rejected in expectation
    """
    return packet_size - bytes_accepted(flow_rate, enforced_limit, packet_size)