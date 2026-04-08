# syntax=docker/dockerfile:1
FROM ocaml/opam:debian-12-ocaml-4.14

WORKDIR /workspace

COPY --chown=opam:opam packages/reventless-ppx/src/*.opam /workspace/reventless-ppx/src/
COPY --chown=opam:opam packages/reventless-ppx/src /workspace/reventless-ppx/src

RUN cd /workspace/reventless-ppx/src && opam install -y --deps-only .

RUN cd /workspace/reventless-ppx/src && opam exec -- dune build

RUN cp /workspace/reventless-ppx/src/_build/install/default/lib/reventless-ppx/ppx.exe /workspace/ppx-linux.exe
