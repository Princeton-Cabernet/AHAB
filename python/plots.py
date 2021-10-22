#!/usr/bin/python3
import numpy as np
from matplotlib.axes import Axes
from approx_qos import QosHistory
from typing import List, Tuple, Type


def print_history_fairness(history: QosHistory):
    for slice_id in range(history.num_slices):
        print("Slice %d: " % slice_id, history.fairness_l2_history_for(slice_id))


def plot_slice_loads(ax: Axes, slice_colors: List[str],
                     history: QosHistory):
    ax.set_title("Slice demand over time")
    ax.set_ylabel("Bytes")
    ax.set_xlabel("EpochID")

    ax.yaxis.grid(color='gray', linestyle='dashed')

    x_vals = list(range(history.num_epochs))
    for slice_id in range(history.num_slices):
        loads = [sum(record.flow_sizes) for record in history.records_for(slice_id)]
        line, = ax.plot(x_vals, loads,
                        label="Slice %d, weight %.3f" % (slice_id, history.slice_weights[slice_id]),
                        linewidth=1.0,
                        linestyle="dashed",
                        color=slice_colors[slice_id])

    ax.legend()


def plot_slice_flow_counts(ax: Axes, slice_colors: List[str],
                           history: QosHistory):
    ax.set_title("Slice flow count over time")
    ax.set_ylabel("Num flows")
    ax.set_xlabel("EpochID")

    ax.yaxis.grid(color='gray', linestyle='dashed')

    x_vals = list(range(history.num_epochs))
    for slice_id in range(history.num_slices):
        counts = [len(record.flow_sizes) for record in history.records_for(slice_id)]
        line, = ax.plot(x_vals, counts,
                        label="Slice %d, weight %.3f" % (slice_id, history.slice_weights[slice_id]),
                        linewidth=1.0,
                        color=slice_colors[slice_id])

    ax.legend()


def plot_history_fairness(ax: Axes, slice_colors: List[str],
                          history: QosHistory):

    ax.set_title("Mean per-flow (drop_rate - ideal_drop_rate) delta")
    ax.set_ylabel("Fairness metric")
    ax.set_xlabel("EpochID")

    ax.yaxis.grid(color='gray', linestyle='dashed')

    x_vals = list(range(history.num_epochs))
    for slice_id in range(history.num_slices):
        fairness_vals = history.fairness_mean_history_for(slice_id)
        line, = ax.plot(x_vals, fairness_vals,linewidth=1.0,
                        color=slice_colors[slice_id])


def plot_threshold_error(ax: Axes, slice_colors: List[str],
                         history: QosHistory):

    ax.set_title("Relative error in approximated threshold")
    ax.set_ylabel("Relative error (0.1 = 10%")
    ax.set_xlabel("EpochID")

    ax.yaxis.grid(color='gray', linestyle='dashed')

    x_vals = list(range(history.num_epochs))
    for slice_id in range(history.num_slices):
        threshold_errors = history.threshold_error_for(slice_id)
        line, = ax.plot(x_vals, threshold_errors,
                        linewidth=1.0, color=slice_colors[slice_id])


def plot_thresholds(ax: Axes, slice_colors: List[str],
                    history: QosHistory):

    ax.set_title("Ideal (solid) and approximated (dashed) thresholds over time")
    ax.set_ylabel("Threshold")
    ax.set_xlabel("EpochID")

    ax.yaxis.grid(color='gray', linestyle='dashed')

    x_vals = list(range(history.num_epochs))
    for slice_id in range(history.num_slices):
        thresholds1 = [record[slice_id].threshold_ideal for record in history.history]
        line, = ax.plot(x_vals, thresholds1, color=slice_colors[slice_id], linewidth=1.0)
        thresholds2 = [record[slice_id].threshold_chosen for record in history.history]
        line, = ax.plot(x_vals, thresholds2, color=slice_colors[slice_id], linewidth=1.0, linestyle="dashed")


def plot_drop_rate_scatter(ax: Axes, slice_colors: List[str],
                           history: QosHistory, slice_weights: List[float]):

    ax.set_title("Drop rate relative to normalized flow size")
    ax.set_ylabel("Drop rate")
    ax.set_xlabel("Per-epoch Flow size, normalized by the epoch's ideal threshold")
    # ax.set_xscale("log")
    ax.yaxis.grid(color='gray', linestyle='dashed')

    largest_x_point: float = 0

    for slice_id in range(history.num_slices):
        points: List[Tuple[float, float]] = []
        # Chop off the first
        for epoch_record in history.history:
            slice_record = epoch_record[slice_id]
            for flow_size, flow_drops in zip(slice_record.flow_sizes, slice_record.flow_drops):
                relative_flow_size = flow_size / slice_record.threshold_ideal
                drop_rate = flow_drops / flow_size
                largest_x_point = max(largest_x_point, relative_flow_size)
                points.append((relative_flow_size, drop_rate))
        ax.scatter([x for x, y in points], [y for x, y in points], alpha=0.3,
                   color=slice_colors[slice_id])
    reference_x = np.linspace(0.1, max(largest_x_point, 2.0), num=100)
    reference_y = [max(x - 1, 0) / max(x, 0.1) for x in reference_x]
    ax.plot(reference_x, reference_y, label="Ideal drop rate", color="black", linewidth=1.0)
    ax.legend()
