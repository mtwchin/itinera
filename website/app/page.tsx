const CompassMark = ({ size = "default" }: { size?: "default" | "large" }) => (
  <span className={`compass-mark compass-mark--${size}`} aria-hidden="true">
    <span />
  </span>
);

const Arrow = () => (
  <span className="button-arrow" aria-hidden="true">
    ↗
  </span>
);

function PlannerMockup() {
  return (
    <div className="planner-mockup" aria-label="Itinera trip planning preview">
      <div className="planner-card planner-card--destination">
        <div className="ui-section-heading">
          <span>01</span>
          <div>
            <strong>Destination</strong>
            <small>Start with where you’re going.</small>
          </div>
        </div>
        <div className="ui-input">
          <span className="pin-dot" aria-hidden="true" />
          Lisbon, Portugal
        </div>
        <div className="ui-success">
          <span aria-hidden="true">✓</span> Destination set
        </div>
      </div>

      <div className="planner-card planner-card--home">
        <div className="ui-section-heading">
          <span>02</span>
          <div>
            <strong>Home base</strong>
            <small>Shape each day around your stay.</small>
          </div>
        </div>
        <div className="ui-input">
          <span className="home-dot" aria-hidden="true" />
          Alfama, Lisbon
        </div>
        <div className="preference-row" aria-label="Selected trip preferences">
          <span>Balanced</span>
          <span>Walk + transit</span>
          <span>Food</span>
          <span>Culture</span>
        </div>
        <div className="mock-button">Build my itinerary</div>
      </div>
      <span className="planner-note planner-note--top">4 days</span>
      <span className="planner-note planner-note--bottom">2 travelers</span>
    </div>
  );
}

function RouteMap() {
  return (
    <div className="route-map" aria-label="Illustrative route through Lisbon">
      <span className="map-label map-label--water">TEJO</span>
      <span className="map-label map-label--alfama">ALFAMA</span>
      <span className="map-label map-label--baixa">BAIXA</span>
      <span className="street street--one" />
      <span className="street street--two" />
      <span className="street street--three" />
      <span className="street street--four" />
      <span className="route-line route-line--one" />
      <span className="route-line route-line--two" />
      <span className="route-line route-line--three" />
      <span className="waypoint waypoint--one">1</span>
      <span className="waypoint waypoint--two">2</span>
      <span className="waypoint waypoint--three">3</span>
      <span className="home-marker" aria-hidden="true">◆</span>
    </div>
  );
}

function ItineraryMockup() {
  return (
    <div className="phone-shell itinerary-shell" aria-label="Sample Itinera day plan">
      <div className="phone-status" aria-hidden="true">
        <span>9:41</span>
        <span>●●●</span>
      </div>
      <div className="app-heading">
        <span className="app-eyebrow">Day 1 of 3</span>
        <h3>Tiles, viewpoints &amp; old Lisbon</h3>
        <p>A paced overview of today’s stops.</p>
      </div>
      <div className="day-tabs" aria-label="Trip day selector">
        <span className="is-active">Day 1</span>
        <span>Day 2</span>
        <span>Day 3</span>
      </div>
      <RouteMap />
      <div className="timeline-card">
        <div className="timeline-rail" aria-hidden="true">
          <span>1</span>
        </div>
        <div className="timeline-time">
          <strong>09:00</strong>
          <span>1 hr</span>
        </div>
        <div className="timeline-copy">
          <h4>Miradouro da Senhora do Monte</h4>
          <p>Start above the tiled rooftops before the city wakes.</p>
          <small>Calçada do Monte, Lisboa</small>
        </div>
      </div>
    </div>
  );
}

function TodayMockup() {
  return (
    <div className="today-wrap">
      <div className="offline-badge">
        <span /> Saved offline
      </div>
      <div className="phone-shell today-shell" aria-label="Sample Itinera Today mode">
        <div className="phone-status" aria-hidden="true">
          <span>11:18</span>
          <span>●●●</span>
        </div>
        <span className="app-eyebrow">Day 1 · Today</span>
        <h3>Lisbon</h3>
        <p className="today-theme">Tiles, viewpoints &amp; old Lisbon</p>
        <div className="progress-card">
          <div>
            <span>Day progress</span>
            <strong>1 of 3 complete</strong>
          </div>
          <div className="progress-track">
            <span />
          </div>
        </div>
        <div className="next-move-label">
          <span>Now</span> Your next move
        </div>
        <div className="next-stop-card">
          <div className="stop-meta">
            <span>Starts at 11:00</span>
            <small>2 hrs</small>
          </div>
          <h4>Alfama lanes</h4>
          <p>Follow the quiet stairways toward the cathedral and river.</p>
          <small>Alfama, Lisboa</small>
          <div className="directions-button">
            <span aria-hidden="true">↗</span> Directions in Apple Maps
          </div>
          <div className="stop-actions">
            <span>✓ Complete</span>
            <span>Skip</span>
          </div>
        </div>
      </div>
    </div>
  );
}

const utilityFeatures = [
  {
    number: "01",
    title: "Live travel legs",
    copy: "Compare walking, transit, and driving time, with a clear fallback when live routes are unavailable.",
    symbol: "→",
  },
  {
    number: "02",
    title: "Plans that flex",
    copy: "Add, reorder, replace, or lock stops. Lighten a day without rebuilding the whole trip.",
    symbol: "⇅",
  },
  {
    number: "03",
    title: "Your whole trip library",
    copy: "Keep active, upcoming, past, and archived trips organized on your iPhone.",
    symbol: "▤",
  },
  {
    number: "04",
    title: "Take it anywhere",
    copy: "Share a trip as text or PDF, add stops to Calendar, or hand a full day to Google Maps.",
    symbol: "↗",
  },
];

export default function Home() {
  return (
    <div className="site-shell">
      <header className="site-header">
        <a className="brand" href="#top" aria-label="Itinera home">
          <CompassMark />
          <span>Itinera</span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#features">Features</a>
          <a href="#how-it-works">How it works</a>
          <a href="#on-the-road">On the road</a>
        </nav>
        <a className="header-cta" href="#testflight">
          TestFlight soon <Arrow />
        </a>
      </header>

      <main id="top">
        <section className="hero" aria-labelledby="hero-title">
          <div className="hero-copy">
            <div className="eyebrow-row">
              <span className="eyebrow">Itinera · Field Guide 01</span>
              <span className="release-badge">Built for iPhone</span>
            </div>
            <h1 id="hero-title">A field guide for the trip you actually take.</h1>
            <p className="hero-lede">
              Build a day-by-day city itinerary around your home base, pace,
              interests, and fixed plans—then keep the next stop, directions,
              and day progress close at hand.
            </p>
            <div className="hero-actions">
              <a className="primary-button" href="#features">
                Explore Itinera <Arrow />
              </a>
              <a className="text-link" href="#lisbon-day">
                See a Lisbon day <span aria-hidden="true">↓</span>
              </a>
            </div>
            <div className="hero-proof" aria-label="Itinera highlights">
              <span>Personalized routes</span>
              <span>Offline trip content</span>
              <span>Private by default</span>
            </div>
          </div>
          <div className="hero-visual">
            <PlannerMockup />
          </div>
        </section>

        <section className="promise-strip" aria-label="Itinera promise">
          <span className="promise-kicker">Pocket field guide</span>
          <p>
            Useful before the trip. Dependable without a connection.
            Adaptable when the day changes.
          </p>
          <CompassMark size="large" />
        </section>

        <section className="feature-section feature-section--plan" id="features">
          <div className="section-copy">
            <span className="section-number">01 / Plan</span>
            <h2>Shaped around your stay.</h2>
            <p>
              Tell Itinera where you’ll wake up, how you like to move, and what
              can’t be missed. It arranges the day around the place you’ll
              actually return to—not just a list of popular pins.
            </p>
            <ul className="feature-list">
              <li>Balance your pace, budget, interests, and accessibility needs</li>
              <li>Protect reservations and free-time blocks</li>
              <li>Keep must-dos while leaving room to wander</li>
            </ul>
          </div>
          <div className="mini-plan-card" aria-label="Personalized trip details">
            <span className="mini-card-label">Trip rhythm</span>
            <div className="trip-route-title">
              <span>LIS</span>
              <div><i /><i /><i /></div>
              <span>4 DAYS</span>
            </div>
            <div className="trip-details">
              <div><small>HOME BASE</small><strong>Alfama</strong></div>
              <div><small>PACE</small><strong>Balanced</strong></div>
              <div><small>MOVE BY</small><strong>Walk + transit</strong></div>
              <div><small>TRAVELERS</small><strong>2 people</strong></div>
            </div>
            <blockquote>“Local food, tiled streets, one slow afternoon.”</blockquote>
          </div>
        </section>

        <section className="feature-section feature-section--route" id="how-it-works">
          <div className="mockup-column" id="lisbon-day">
            <ItineraryMockup />
            <p className="mockup-caption">
              Illustrative itinerary · live hours and routes may vary
            </p>
          </div>
          <div className="section-copy">
            <span className="section-number">02 / Explore</span>
            <h2>A route, not a list.</h2>
            <p>
              Every day has a shape. See stops in a sensible order, understand
              the travel between them, and open the route in the map you
              already use.
            </p>
            <div className="route-stats" aria-label="Sample itinerary details">
              <div><strong>3</strong><span>paced stops</span></div>
              <div><strong>2.8 km</strong><span>on foot</span></div>
              <div><strong>38 min</strong><span>between stops</span></div>
            </div>
            <div className="field-note">
              <span>Field note</span>
              <p>
                Wear shoes with grip—Lisbon’s calçada streets become slick
                after rain.
              </p>
            </div>
          </div>
        </section>

        <section className="feature-section feature-section--today" id="on-the-road">
          <div className="section-copy">
            <span className="section-number">03 / Go</span>
            <h2>Ready when the day starts.</h2>
            <p>
              Today mode keeps your current stop, next move, directions, and
              progress close. Completed trip content stays available offline;
              live maps and travel updates reconnect when you do.
            </p>
            <div className="today-benefits">
              <div>
                <span className="benefit-icon">◉</span>
                <p><strong>Know what’s next</strong><small>See current and upcoming stops at a glance.</small></p>
              </div>
              <div>
                <span className="benefit-icon">↗</span>
                <p><strong>Move with confidence</strong><small>Open one-tap directions in Apple Maps.</small></p>
              </div>
              <div>
                <span className="benefit-icon">✓</span>
                <p><strong>Make the day yours</strong><small>Complete, skip, or adjust stops as you go.</small></p>
              </div>
            </div>
          </div>
          <TodayMockup />
        </section>

        <section className="utility-section" aria-labelledby="utility-title">
          <div className="utility-heading">
            <span className="section-number">More in your pocket</span>
            <h2 id="utility-title">From first idea to last stop.</h2>
            <p>Practical travel tools, without the travel-dashboard clutter.</p>
          </div>
          <div className="utility-grid">
            {utilityFeatures.map((feature) => (
              <article key={feature.number} className="utility-card">
                <div className="utility-card-top">
                  <span>{feature.number}</span>
                  <i aria-hidden="true">{feature.symbol}</i>
                </div>
                <h3>{feature.title}</h3>
                <p>{feature.copy}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="privacy-section" aria-labelledby="privacy-title">
          <div className="privacy-route" aria-hidden="true">
            <span>1</span><i /><span>2</span><i /><span>3</span>
          </div>
          <div className="privacy-copy">
            <span className="section-number">Private by default</span>
            <h2 id="privacy-title">Your plans are yours.</h2>
            <p>
              Trips are owner-scoped, AI data use is explained before planning,
              and you can delete your account data from Settings. Sharing only
              happens when you choose it.
            </p>
          </div>
          <div className="privacy-points">
            <div><span>✓</span><p><strong>Guest-first</strong><small>Start without building a public profile.</small></p></div>
            <div><span>✓</span><p><strong>Clear consent</strong><small>Review how trip details support itinerary planning.</small></p></div>
            <div><span>✓</span><p><strong>Delete My Data</strong><small>Account and local cleanup controls live in the app.</small></p></div>
          </div>
        </section>

        <section className="final-cta" id="testflight" aria-labelledby="final-title">
          <div className="final-cta-copy">
            <span className="eyebrow">Itinera for iPhone</span>
            <h2 id="final-title">Your next day, already mapped.</h2>
            <p>
              Itinera is preparing for TestFlight. Follow the route here as the
              pocket field guide gets ready for its first travelers.
            </p>
          </div>
          <div className="testflight-card">
            <CompassMark size="large" />
            <div>
              <span>Next destination</span>
              <strong>Internal TestFlight</strong>
            </div>
            <span className="testflight-status">In preparation</span>
          </div>
        </section>
      </main>

      <footer>
        <a className="brand" href="#top" aria-label="Back to top">
          <CompassMark />
          <span>Itinera</span>
        </a>
        <p>A calm, dependable field guide for iPhone.</p>
        <span>© 2026 Itinera</span>
      </footer>
    </div>
  );
}
