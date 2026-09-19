# No include, a terraform block without a source, and that block twice.

terraform {
  # no source
}

terraform {
  # still no source
}

inputs = {
  name = "example"
}
