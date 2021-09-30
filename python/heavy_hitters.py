import random
from abc import ABC, abstractmethod
from collections import defaultdict
from typing import Tuple, Dict, List, Callable, Optional

from hashing import make_crc16_func, CRC16_DEFAULT_POLY

from statistics import median


class HeavyHitterSketch(ABC):
    @abstractmethod
    def clear(self) -> None:
        """
        Clear the sketch
        :return: None
        """
        pass

    @abstractmethod
    def set(self, key: Tuple[int], set_val: int = 1) -> int:
        """
        Set the count of the item
        :param key: item key
        :param set_val: item count
        :return:
        """
        return NotImplemented

    @abstractmethod
    def get(self, key: Tuple[int]) -> int:
        """
        Get an item's count.
        :param key: item key
        :return: item count
        """
        return NotImplemented

    @abstractmethod
    def add(self, key: Tuple[int], add_val: int = 1) -> int:
        """
        Add to the item's count
        :param key: item key
        :param add_val: value to add to the item's count
        :return: item count, after the addition
        """
        return NotImplemented

    @abstractmethod
    def add_after_return(self, key: Tuple[int], add_val: int = 1) -> int:
        """
        Same as `add`, but returns the original value before the addition occurred.
        :param key: item key
        :param add_val: value to add to the item's count
        :return: item count, before the addition
        """
        return NotImplemented


class ExactHeavyHitters(HeavyHitterSketch):
    ground_truth: Dict[Tuple[int], int]

    def __init__(self):
        self.clear()

    def clear(self):
        self.ground_truth = defaultdict(int)

    def set(self, key: Tuple[int], set_val: int = 1) -> int:
        self.ground_truth[key] = set_val
        return set_val

    def get(self, key: Tuple[int]) -> int:
        return self.ground_truth[key]

    def add(self, key: Tuple[int], add_val: int = 1) -> int:
        val = self.ground_truth[key] + add_val
        self.ground_truth[key] = val
        return val

    def add_after_return(self, key: Tuple[int], add_val: int = 1) -> int:
        val = self.ground_truth[key]
        self.ground_truth[key] = val + add_val
        return val


class CountSketch(HeavyHitterSketch):
    arrays: List[List[int]]
    height: int
    width: int
    salts: List[int]
    index_hash_funcs: List[Callable[..., int]]
    sign_hash_funcs: List[Callable[..., int]]
    ground_truth: Dict[Tuple[int], int]

    def __init__(self, width: int = 3, height: int = 65536):
        self.width = width
        self.height = height
        self.arrays = [[0] * self.height for _ in range(self.width)]
        self.index_hash_funcs = [make_crc16_func(polynomial=CRC16_DEFAULT_POLY
                                                 + (0x100 * i)) for i in range(width)]
        self.sign_hash_funcs = [make_crc16_func(polynomial=CRC16_DEFAULT_POLY
                                                + (0x100 * (i + width))) for i in range(width)]

    def clear(self):
        self.arrays = [[0] * self.height for _ in range(self.width)]

    def set(self, key: Tuple[int], set_val: int = 1) -> int:
        # Doesn't make sense for count sketch
        return NotImplemented

    def get_all(self, key: Tuple[int]) -> Tuple[int]:
        """
        Return one value from each array for the given item key, instead of just the median.
        :param key: item key
        :return: all values that the item key hashed to
        """
        return tuple(array[index] for array, index in zip(self.arrays, self.indices(key)))

    def get(self, key: Tuple[int]) -> int:
        return abs(median(self.get_all(key)))

    def add(self, key: Tuple[int], add_val: int = 1) -> int:
        vals = []
        for index, sign, array in zip(self.indices(key), self.signs(key), self.arrays):
            val = array[index] + add_val * sign
            array[index] = val
            vals.append(val)
        return abs(median(vals))

    def add_after_return(self, key: Tuple[int], add_val: int = 1) -> int:
        vals = []
        for index, sign, array in zip(self.indices(key), self.signs(key), self.arrays):
            val = array[index]
            array[index] = val + add_val * sign
            vals.append(val)
        return abs(median(vals))

    def indices(self, key: Tuple[int]) -> Tuple[int]:
        return tuple(hash_func(*key) % self.height for hash_func in self.index_hash_funcs)

    def signs(self, key: Tuple[int]) -> Tuple[int]:
        return tuple((hash_func(*key) % 2) * 2 - 1 for hash_func in self.sign_hash_funcs)


class CountMinSketch(HeavyHitterSketch):
    arrays: List[List[int]]
    height: int
    width: int
    salts: List[int]
    hash_funcs: List[Callable[..., int]]
    ground_truth: Dict[Tuple[int], int]

    def __init__(self, width: int = 3, hash_funcs: Optional[List[Callable[..., int]]] = None,
                 salts: Optional[List[int]] = None, height: int = 65536):
        """
        :param width: Number of arrays to use. If `hash_funcs` is provided, the number of funcs is used instead
        :param hash_funcs: callables that take a variable number of integers and output a hash
        :param salts: fixed, additional inputs to each hash function
        :param height: number of cells in each array in the CMS
        """
        self.height = height

        if hash_funcs is None:
            self.width = width
            self.hash_funcs = [make_crc16_func(polynomial=CRC16_DEFAULT_POLY + (0x100 * i)) for i in range(width)]
        else:
            self.width = len(hash_funcs)
            self.hash_funcs = hash_funcs.copy()
        if salts is None:
            self.salts = [0] * self.height
        else:
            assert (len(salts) == len(hash_funcs))
            self.salts = salts

        self.arrays = [[0] * self.height for _ in range(self.width)]
        self.ground_truth = defaultdict(int)

    def set(self, key: Tuple[int], insert_val: int = 1) -> None:
        """
        Set the CMS value for the given item key. Overwrites every array cell that `key` hashes to.
        Useful for treating this class like a bloom filter, albeit an inefficient one.
        :param key: item key
        :param insert_val: value to set for the given item key.
        :return: None
        """
        self.ground_truth[key] = insert_val
        for array, index in zip(self.arrays, self.indices(key)):
            array[index] = insert_val

    def add(self, key: Tuple[int], add_val: int = 1) -> int:
        """
        Add `add_val` to the CMS for the given item key
        :param key: item key
        :param add_val: value to add to the item's value
        :return: The CMS value for the given item key, after the addition
        """
        self.ground_truth[key] += add_val
        smallest = None
        for array, index in zip(self.arrays, self.indices(key)):
            val = array[index] + add_val
            array[index] = val
            smallest = val if smallest is None or val < smallest else smallest
        return smallest

    def add_after_return(self, key: Tuple[int], add_val: int = 1) -> int:
        """
        Add `add_val` to the CMS for the given item key. Same as `add()`, but returns the CMS value pre-addition
        instead of post-addition.
        :param key: item key
        :param add_val: value to add to the item's value
        :return: The CMS value for the given item key, before the addition occurred
        """
        # Same as add, but returns the old value before the addition occurred
        self.ground_truth[key] += add_val
        smallest = None
        for array, index in zip(self.arrays, self.indices(key)):
            val = array[index]
            array[index] = val + add_val
            smallest = val if smallest is None or val < smallest else smallest
        return smallest

    def get(self, key: Tuple[int]) -> int:
        """
        Get the CMS value for the given item key
        :param key: item key
        :return: CMS value ie the min of all values the item key hashes to
        """
        return min(array[index] for array, index in zip(self.arrays, self.indices(key)))

    def clear(self):
        self.arrays = [[0] * self.height for _ in range(self.width)]
        self.ground_truth.clear()

    def subtract(self, key: Tuple[int], sub_val: int) -> int:
        """
        Subtract `sub_val` from the CMS for the given item key
        :param key: item key
        :param sub_val: value to subtract from the item's value
        :return: The resulting CMS value after subtraction
        """
        return self.add(key, add_val=-sub_val)

    def get_all(self, key: Tuple[int]) -> Tuple[int]:
        """
        Return one value from each array for the given item key, instead of just the min.
        :param key: item key
        :return: all values that the item key hashed to
        """
        return tuple(array[index] for array, index in zip(self.arrays, self.indices(key)))

    def indices(self, key: Tuple[int]) -> Tuple[int]:
        """
        Return indices (hash values modulo array lengths) for all arrays in the CMS for the given key.
        :param key: the key to hash
        :return: a tuple of array indices
        """
        return tuple(hash_func(*key, salt) % self.height
                     for hash_func, salt in zip(self.hash_funcs, self.salts))


def test_cms():
    print("Check 1")
    cms = CountMinSketch()
    for i in range(100000):
        key = (random.randint(0, 100000),)
        val = cms.add(key=key, add_val=random.randint(0, 5))
        if val < cms.ground_truth[key]:
            print("CMS `add` messed up")
            exit(1)

    print("Check 2")
    cms = CountMinSketch()
    for i in range(10000):
        key = (random.randint(0, 100000),)
        add_val = random.randint(0, 5)
        val1 = cms.get(key=key)
        val2 = cms.add_after_return(key=key, add_val=add_val)
        val3 = cms.get(key=key)
        if val1 != val2 or val2 + add_val != val3:
            print("CMS `return_then_add` messed up")
            exit(1)
    print("CMS didn't mess up")


def test_cs():
    cs = CountSketch()
    ground_truth: Dict[Tuple[int], int] = defaultdict(int)
    for i in range(10000):
        key = (random.randint(0, 10000) * 20,)
        add_val = add_val=random.randint(1, 5)
        ground_truth[key] += add_val
        cs_val = cs.add(key=key, add_val=add_val)
        true_val = ground_truth[key]

    errors = []
    for key, true_val in ground_truth.items():
        cs_val = cs.get(key)
        error = abs(cs_val - true_val) / true_val
        errors.append(error)
    errors.sort()
    num_errs = len(errors)
    err50 = errors[int(num_errs * 0.5)]
    err90 = errors[int(num_errs * 0.9)]
    err95 = errors[int(num_errs * 0.95)]
    err99 = errors[int(num_errs * 0.99)]
    print("CountSketch error quantiles: 50%%: %.2f, 90%%: %.2f, 95%%: %.2f, 99%%: %.2f" % (err50, err90, err95, err99))


if __name__ == "__main__":
    test_cms()
    test_cs()
