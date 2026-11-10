// The reference is long, so it is filterable: one field narrows the page to the
// declarations whose name, kind or prose matches, and packages that keep nothing
// fold away with it.

const field = document.getElementById("q");
const hits = document.getElementById("hits");
const modules = [...document.querySelectorAll(".mod")];

function filter() {
  const needle = field.value.trim().toLowerCase();
  let shown = 0;
  for (const mod of modules) {
    let inModule = 0;
    for (const pkg of mod.querySelectorAll(".pkg")) {
      let inPackage = 0;
      for (const entry of pkg.querySelectorAll(".entry")) {
        const hay = (entry.dataset.name || "") + " " + entry.textContent.toLowerCase();
        const match = needle === "" || hay.includes(needle);
        entry.classList.toggle("hide", !match);
        if (match) inPackage += 1;
      }
      pkg.classList.toggle("hide", inPackage === 0);
      inModule += inPackage;
    }
    mod.classList.toggle("hide", inModule === 0);
    shown += inModule;
  }
  hits.textContent = needle === "" ? "" : shown + " shown";
}

field.addEventListener("input", filter);
hits.textContent = "";
