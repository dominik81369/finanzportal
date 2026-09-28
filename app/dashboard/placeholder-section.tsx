/**
 * Platzhalter für Dashboard-Bereiche, deren Oberfläche noch folgt. Nennt,
 * was geplant ist, damit die Seite nicht wie ein Fehler wirkt.
 */
export function PlaceholderSection({
  title,
  description,
  planned,
}: {
  title: string;
  description: string;
  planned: readonly string[];
}) {
  return (
    <section className="placeholder" aria-labelledby="page-title">
      <h1 id="page-title">{title}</h1>
      <p>{description}</p>
      <div className="placeholder-box">
        <p className="placeholder-label">In Vorbereitung</p>
        <ul>
          {planned.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </div>
    </section>
  );
}
