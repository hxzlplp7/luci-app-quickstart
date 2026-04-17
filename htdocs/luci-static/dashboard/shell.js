function createSectionState(expanded) {
  return {
    expanded,
    loaded: false,
    loading: false,
    error: null,
  };
}

export function buildSectionState() {
  return {
    overview: createSectionState(true),
  };
}
