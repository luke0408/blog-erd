import { mkdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname } from "node:path";
import { PrismaMarkdown } from "prisma-markdown";

const require = createRequire(import.meta.url);
const rendererRequire = createRequire(require.resolve("prisma-markdown"));
const { generatorHandler } = rendererRequire("@prisma/generator-helper");
const { version } = require("prisma-markdown/package.json");

generatorHandler({
  onManifest: () => ({
    version,
    defaultOutput: "./erd.md",
    prettyName: "prisma-markdown",
  }),
  onGenerate: async (options) => {
    const markdown = PrismaMarkdown.write(options.dmmf.datamodel, options.generator.config);
    // Prisma strips indentation from documentation before passing it to generators.
    const formatted = markdown.replace(
      /^```json[\t ]*\r?\n([\s\S]*?)^```[\t ]*$/gm,
      (_, json) => "```json\n" + JSON.stringify(JSON.parse(json), null, 2) + "\n```",
    ).replace(/^```mermaid\n([\s\S]*?)^```/gm, (_, diagram) => {
      // prisma-markdown marks relation scalars as FK even without physical constraints.
      const logical = diagram.replace(
        /^(\s+\S+\s+\S+)\s+((?:PK|FK|UK)(?:,(?:PK|FK|UK))*)(.*)$/gm,
        (_, column, keys, suffix) => {
          const retained = keys.split(",").filter((key) => key !== "FK").join(",");
          return column + (retained ? " " + retained : "") + suffix;
        },
      );
      return "```mermaid\n" + logical + "```";
    });
    const output = options.generator.output?.value ?? "./erd.md";
    await mkdir(dirname(output), { recursive: true });
    await writeFile(output, formatted, "utf8");
  },
});
