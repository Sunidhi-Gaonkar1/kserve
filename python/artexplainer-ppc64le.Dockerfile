ARG PYTHON_VERSION=3.11
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-bookworm
ARG VENV_PATH=/prod_venv

FROM ${BASE_IMAGE} AS builder

# Required for building packages for arm64 arch
RUN apt-get update && apt-get install -y --no-install-recommends curl python3-dev build-essential gcc gfortran cmake pkg-config libssl-dev libopenblas-dev libjpeg-dev libhdf5-dev wget && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    ln -s /root/.local/bin/uv /usr/local/bin/uv

# Setup virtual environment
ARG VENV_PATH
ENV VIRTUAL_ENV=${VENV_PATH}
RUN uv venv $VIRTUAL_ENV && \
    $VIRTUAL_ENV/bin/python -m ensurepip && \
    $VIRTUAL_ENV/bin/python -m pip install --upgrade pip setuptools wheel
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
ENV GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=1

# Copy storage directory for editable install
COPY storage storage

# ------------------ kserve deps ------------------
COPY kserve/pyproject.toml kserve/uv.lock kserve/
RUN echo "===== kserve/uv.lock content =====" && \
    cat kserve/uv.lock || echo "No uv.lock found" && \
    echo "==================================="

# ----- use conda ----------
RUN wget https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-ppc64le.sh && \
    sh Miniconda3-latest-Linux-ppc64le.sh -u -b -p $HOME/conda && \
    $HOME/conda/bin/conda update -y -n base conda && \
    export PATH=$HOME/conda/bin/:$PATH && \
    conda --version
RUN  export PATH=$HOME/conda/bin/:$PATH && conda install conda-forge::h5py==3.10

# Preinstall core dependencies using prebuilt IBM wheels
RUN which pip && python -m site
RUN $VIRTUAL_ENV/bin/python -m pip install --prefer-binary \
      pandas==2.2.3 grpcio==1.71.0 pyyaml==6.0.2 httptools==0.6.4 \
      psutil==5.9.8 \
      --extra-index-url=https://wheels.developerfirst.ibm.com/ppc64le/linux

# Configure uv to reuse binaries and same index
ENV UV_EXTRA_INDEX_URL="https://pypi.org/simple https://wheels.developerfirst.ibm.com/ppc64le/linux"
ENV UV_INDEX_STRATEGY=unsafe-best-match
RUN cd kserve && uv sync --active --no-reinstall --frozen

COPY kserve kserve
RUN cd kserve && uv sync --active --no-reinstall --frozen

# ------------------ artexplainer deps ------------------
COPY artexplainer/pyproject.toml artexplainer/uv.lock artexplainer/
RUN uv venv $VIRTUAL_ENV && \
    $VIRTUAL_ENV/bin/python -m ensurepip && \
    $VIRTUAL_ENV/bin/python -m pip install --upgrade pip setuptools wheel
RUN $VIRTUAL_ENV/bin/python -m pip install --prefer-binary \
      ml-dtypes==0.5.1 scikit-learn==1.6.1 pillow==10.4.0 scipy==1.15.2 \
      --extra-index-url=https://wheels.developerfirst.ibm.com/ppc64le/linux

RUN cd artexplainer && uv sync --active --no-reinstall --frozen

COPY artexplainer artexplainer
RUN cd artexplainer && uv sync --active --no-reinstall --frozen

# Generate third-party licenses
COPY pyproject.toml pyproject.toml
COPY third_party/pip-licenses.py pip-licenses.py
# TODO: Remove this when upgrading to python 3.11+
RUN pip install --no-cache-dir tomli
RUN mkdir -p third_party/library && python3 pip-licenses.py


# ------------------ Production stage ------------------
FROM ${BASE_IMAGE} AS prod

# Activate virtual env
ARG VENV_PATH
ENV VIRTUAL_ENV=${VENV_PATH}
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

COPY third_party third_party

RUN useradd kserve -m -u 1000 -d /home/kserve

COPY --from=builder --chown=kserve:kserve third_party third_party
COPY --from=builder --chown=kserve:kserve $VIRTUAL_ENV $VIRTUAL_ENV
COPY --from=builder kserve kserve
COPY --from=builder artexplainer artexplainer

USER 1000
ENV PYTHONPATH=/artexplainer
ENTRYPOINT ["python", "-m", "artserver"]
