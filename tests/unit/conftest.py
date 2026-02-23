import sys
import os

import pytest
from prometheus_client import REGISTRY

# Add project root to path so we can import monitoring
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))


@pytest.fixture(autouse=True)
def clear_prometheus_registry():
    """Clear Prometheus collectors between tests to avoid duplicate registration."""
    yield
    collectors = list(REGISTRY._names_to_collectors.values())
    for collector in collectors:
        try:
            REGISTRY.unregister(collector)
        except Exception:
            pass
