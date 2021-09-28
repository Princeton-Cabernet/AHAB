from functools import partial
import crcmod
from typing import Callable

CRC16_DEFAULT_POLY = 0x18005


def run_crcmod_func(crc_func: Callable[[bytes], int], *nums: int) -> int:
    """
    Pass inputs to the CRC function and return the output
    :param crc_func: CRC function created using crcmod.mkCrcFun
    :param nums: CRC inputs
    :return: CRC output
    """
    crc_input = bytes(0)
    for num in nums:
        num = int(num)
        crc_input += num.to_bytes((num.bit_length() + 7) // 8, byteorder='big')
    return crc_func(crc_input)


def make_crc16_func(polynomial: int = CRC16_DEFAULT_POLY) -> Callable[..., int]:
    """
    Given a CRC polynomial (and optionally a salt), return a function for computing CRC outputs
    :param polynomial: the CRC polynomial
    :param salt: the CRC salt
    :return: a CRC function
    """
    return partial(run_crcmod_func, crcmod.mkCrcFun(poly=polynomial, initCrc=0))


CRC16 = make_crc16_func(polynomial=CRC16_DEFAULT_POLY)
